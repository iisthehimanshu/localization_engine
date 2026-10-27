// tool/replay_session_positions.dart
//
// Terminal-only debug harness: prints every position [BLEPositionEstimator]
// would have returned for a recorded session log — time, x, y, lat, lng, floor,
// bid, one row per position. Nothing here ships in the package.
//
// Run:
//   dart run tool/replay_session_positions.dart --log ~/Downloads/session.jsonl
//
// Options:
//   --venue "X"        venue to fetch beacons for (default: the log's venueName)
//   --env prod|dev     backend to fetch them from (default: prod)
//   --beacons f.json   use a saved beacon JSON array instead of the backend
//   --walking true|false  force one motion profile for the whole replay
//                      (default: follow the session — see replaySessionLog)

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:localization_engine/src/localizationAlgorithm/ble_position_estimator.dart';
import 'package:localization_engine/src/network/model/beaconData.dart';

// dart run tool/replay_session_positions.dart --log "/Users/himanshu/Downloads/1791470955864-705255234-sensor_nav-AIGHospital-1791470879027_AP3A.240617.008_1791470950869.jsonl"

// ── Backend config (mirrors lib/src/config/config.dart) ──────────────────────
const _envConfig = {
  'prod': {
    'baseUrl': 'https://maps.iwayplus.in',
    'apiKey': '63a0a740-cc23-11f0-b58c-17043284b6b2',
  },
  'dev': {
    'baseUrl': 'https://dev.iwayplus.in',
    'apiKey': '7cc62870-d67e-11f0-91ed-2f0eb903e7db',
  },
};

Map<String, String> parseArgs(List<String> args) {
  final m = <String, String>{};
  for (var i = 0; i + 1 < args.length; i += 2) {
    if (args[i].startsWith('--')) m[args[i].substring(2)] = args[i + 1];
  }
  return m;
}

/// The `--walking` option: null when absent, so the replay follows the session.
bool? walkingOption(Map<String, String> opts) {
  final w = opts['walking'];
  return w == null ? null : w == 'true';
}

String _expandHome(String p) =>
    p.startsWith('~') ? p.replaceFirst('~', Platform.environment['HOME']!) : p;

/// The venue the session was recorded at, read from the log's own records.
String? _venueOf(String jsonl) {
  final m = RegExp(r'"venueName":"([^"]+)"').firstMatch(jsonl);
  return m?.group(1);
}

Future<List<dynamic>> _loadBeacons(
    String? beaconJsonPath, String env, String? venue) async {
  if (beaconJsonPath != null) {
    return json.decode(File(_expandHome(beaconJsonPath)).readAsStringSync());
  }
  final cfg = _envConfig[env];
  if (cfg == null) throw Exception('Unknown --env "$env" (use prod|dev)');
  if (venue == null) {
    throw Exception('No venueName in the log — pass --venue or --beacons');
  }
  final url = '${cfg['baseUrl']}/secured/venue/beacons?api_key=${cfg['apiKey']}';
  stderr.writeln('Fetching beacon map for "$venue" from ${cfg['baseUrl']}');
  final resp = await http.post(
    Uri.parse(url),
    body: jsonEncode({'venueName': venue}),
    headers: {'Content-Type': 'application/json'},
  );
  if (resp.statusCode != 200) {
    throw Exception('Beacon fetch failed: HTTP ${resp.statusCode} — ${resp.body}');
  }
  return json.decode(resp.body);
}

/// Reads the session log at [logPath] and the beacon map it should be replayed
/// against (see the `--venue`, `--env` and `--beacons` options), plus the names
/// of the beacons the backend gives a negative priority — [Beacon] does not
/// keep that field.
Future<(String, Map<String, Beacon>, Set<String>)> loadSession(
    String logPath, Map<String, String> opts) async {
  // The recorder occasionally writes NUL bytes; strip them before decoding.
  final bytes = File(_expandHome(logPath)).readAsBytesSync();
  final jsonl =
      utf8.decode(bytes.where((b) => b != 0).toList(), allowMalformed: true);

  final body = await _loadBeacons(
      opts['beacons'], (opts['env'] ?? 'prod').toLowerCase(),
      opts['venue'] ?? _venueOf(jsonl));
  final beaconDb = <String, Beacon>{};
  final negativePriority = <String>{};
  for (final b in body) {
    final beacon = Beacon.fromJson(b as Map<dynamic, dynamic>);
    if (beacon.name == null) continue;
    beaconDb[beacon.name!] = beacon;
    final properties = b['properties'];
    final priority = properties is Map
        ? int.tryParse(properties['priority'].toString())
        : null;
    if (priority != null && priority.isNegative) {
      negativePriority.add(beacon.name!);
    }
  }
  stderr.writeln('Loaded ${beaconDb.length} beacons.');
  return (jsonl, beaconDb, negativePriority);
}

/// Replays a session log through the real estimator and returns every position
/// it returned, in order, as `{ts, x, y, lat, lng, floor, bid, rank1, rssi}`
/// maps. `ts` is the instant the position was returned at — the close of its
/// bucket; `rank1`/`rssi` are the strongest beacon behind it and its RSSI.
///
/// The replay mirrors the estimator behind `estimatorLocationStream`, which is
/// what navigation_sdk relocalizes from. That estimator is created when
/// navigation starts (DirectionHeader → initEstimatorLocationStream), and
/// startNavigation calls `setWalking(true)` at the same moment. So the replay
/// starts at the log's first `"type":"route"` record — readings before it are
/// dropped — and resolves every bucket with `walking: true`. A log with no
/// route record never started navigating: it is replayed from its first
/// record with `walking: false`, the engine's default.
///
/// Pass [walking] to force one value for every bucket instead. The start point
/// is the same either way.
///
/// The log's `"type":"ble"` records are batched the way the live loop batches
/// them: a record joins the 1-second bucket it *arrived* in (its `ts`), keeps
/// the detection time the scanner stamped it with (`scanData.timestamp`), and
/// each bucket is resolved with the clock set to the instant it closed.
/// Buckets that resolved nothing (update() returned null) contribute no entry.
///
/// Where the bucket boundaries fall matters as much as anything else here: a
/// grid a few hundred milliseconds off hands the estimator different batches,
/// and the replayed fixes stop matching the live ones. The live timer's phase
/// is not recorded directly, but the SDK writes its `reloc` and `reroute`
/// records straight off an estimator fix, within a few milliseconds of the
/// tick that produced it — so the grid is aligned to the median sub-second
/// phase of those records. A log with neither falls back to a grid anchored
/// on the start point, which is only right by luck.
List<Map<String, dynamic>> replaySessionLog(
  String jsonl,
  Map<String, Beacon> beaconDb, {
  bool? walking,
  Duration tick = const Duration(seconds: 1),
}) {
  // (arrival, reading) for every BLE record in the log.
  final scans = <MapEntry<DateTime, BleReading>>[];
  // When navigation started — the first route record's `ts`.
  DateTime? navStart;
  // Records the SDK writes right after a live estimator tick.
  final tickMarks = <DateTime>[];
  for (final line in const LineSplitter().convert(jsonl)) {
    if (line.trim().isEmpty) continue;
    final Object? rec;
    try {
      rec = json.decode(line);
    } on FormatException {
      continue; // a session killed mid-write leaves a torn last line
    }
    if (rec is! Map) continue;
    if (rec['type'] == 'route') {
      navStart ??= DateTime.tryParse(rec['ts']?.toString() ?? '');
      continue;
    }
    if (rec['type'] == 'reloc' || rec['type'] == 'reroute') {
      final ts = DateTime.tryParse(rec['ts']?.toString() ?? '');
      if (ts != null) tickMarks.add(ts);
      continue;
    }
    if (rec['type'] != 'ble') continue;
    final scan = rec['scanData'];
    if (scan is! Map) continue;
    final name = scan['name'];
    final rssi = scan['rssi'];
    final arrival = DateTime.tryParse(rec['ts']?.toString() ?? '');
    if (name is! String || rssi is! num || arrival == null) continue;
    final detected = scan['timestamp'];
    scans.add(MapEntry(
      arrival,
      BleReading(
        name: name,
        rssi: rssi.round(),
        timestamp: detected is int
            ? DateTime.fromMillisecondsSinceEpoch(detected)
            : arrival,
      ),
    ));
  }
  if (navStart != null) scans.removeWhere((s) => s.key.isBefore(navStart!));
  if (scans.isEmpty) return const [];
  scans.sort((a, b) => a.key.compareTo(b.key));

  final start = navStart ?? scans.first.key;
  final phase = liveTickPhase(tickMarks, tick);
  // The last live tick at or before [start], so the first bucket is the one
  // the live loop was collecting when navigation began.
  final anchor = phase == null
      ? start
      : start.subtract(Duration(
          microseconds: (start.microsecondsSinceEpoch - phase) %
              tick.inMicroseconds));
  final walkingAll = walking ?? navStart != null;
  var bucket = 0;
  final est = BLEPositionEstimator(
    beaconDb: beaconDb,
    clock: () => anchor.add(tick * (bucket + 1)),
  );

  final positions = <Map<String, dynamic>>[];
  var batch = <BleReading>[];
  void flush() {
    final pos = est.update(batch, walking: walkingAll);
    batch = [];
    if (pos == null) return;
    positions.add({
      'ts': anchor.add(tick * (bucket + 1)),
      'x': pos.smoothX,
      'y': pos.smoothY,
      'lat': pos.smoothLat,
      'lng': pos.smoothLon,
      'floor': pos.floor,
      'bid': pos.building,
      'rank1': pos.rank1Beacon,
      'rssi': pos.rank1Rssi,
    });
  }

  for (final s in scans) {
    final b = s.key.difference(anchor).inMicroseconds ~/ tick.inMicroseconds;
    // Silent seconds are still updates live — the timer fires regardless.
    for (; bucket < b; bucket++) {
      flush();
    }
    batch.add(s.value);
  }
  flush();
  return positions;
}

/// The live estimator timer's phase — microseconds past each [tick] boundary
/// at which it fires — read off [marks], or null when there are none.
///
/// Taken as a median rather than a mean because a mark is occasionally written
/// late (a busy frame, an awaited relocalize). The offsets are measured around
/// the first mark's phase so that marks straddling a second boundary (.98 and
/// .02) are treated as neighbours rather than as opposite ends of the second.
int? liveTickPhase(List<DateTime> marks, Duration tick) {
  if (marks.isEmpty) return null;
  final t = tick.inMicroseconds;
  final ref = marks.first.microsecondsSinceEpoch % t;
  final offsets = [
    for (final m in marks)
      ((m.microsecondsSinceEpoch % t - ref + t + t ~/ 2) % t) - t ~/ 2
  ]..sort();
  return (ref + offsets[offsets.length ~/ 2]) % t;
}

Future<void> main(List<String> args) async {
  final opts = parseArgs(args);
  final logPath = opts['log'];
  if (logPath == null) {
    stderr.writeln('Usage: dart run tool/replay_session_positions.dart '
        '--log <session.jsonl> [--venue X] [--env prod|dev] '
        '[--beacons f.json] [--walking true|false]');
    exit(2);
  }

  final (jsonl, beaconDb, _) = await loadSession(logPath, opts);

  final positions = replaySessionLog(
    jsonl,
    beaconDb,
    walking: walkingOption(opts),
  );
  stderr.writeln('${positions.length} positions.');

  String f(num? v, int digits) => v == null ? '-' : v.toStringAsFixed(digits);
  stdout.writeln('${'time'.padRight(23)} '
      '${'x'.padLeft(8)} ${'y'.padLeft(8)} ${'lat'.padLeft(12)} '
      '${'lng'.padLeft(12)} ${'floor'.padLeft(5)}  bid');
  for (final p in positions) {
    final ts = (p['ts'] as DateTime).toLocal().toIso8601String();
    stdout.writeln('${ts.substring(0, 23).replaceFirst('T', ' ')} '
        '${f(p['x'], 2).padLeft(8)} ${f(p['y'], 2).padLeft(8)} '
        '${f(p['lat'], 7).padLeft(12)} ${f(p['lng'], 7).padLeft(12)} '
        '${'${p['floor']}'.padLeft(5)}  ${p['bid']}');
  }
}
