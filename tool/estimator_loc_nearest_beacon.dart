// tool/estimator_loc_nearest_beacon.dart
//
// Terminal-only debug harness: lists every `"type":"estimatorLoc"` record a
// session log recorded — the positions the live estimator actually returned,
// no replay — and, for each, the nearest beacon on the same floor of the same
// building with the distance between them in feet. Nothing here ships in the
// package.
//
// When the log's `bid` matches no beacon's building_ID (the estimator can
// report a different building ID than the beacon map uses), beacons are
// matched on floor alone and a warning is printed.
//
// Run:
//   dart run tool/estimator_loc_nearest_beacon.dart --log ~/Downloads/session.jsonl
//
// Options:
//   --venue "X"        venue to fetch beacons for (default: the log's venueName)
//   --env prod|dev     backend to fetch them from (default: prod)
//   --beacons f.json   use a saved beacon JSON array instead of the backend

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:localization_engine/src/network/model/beaconData.dart';

import 'replay_session_positions.dart';

// Metres per floor-plan grid unit (mirrors Beacon.distanceTo).
const _metresPerUnit = 1.0;
const _feetPerMetre = 1;
// Rows at most this far from their nearest beacon get a tick mark.
const _tickFeet = 7.0;

Future<void> main(List<String> args) async {
  final opts = parseArgs(args);
  final logPath = opts['log'];
  if (logPath == null) {
    stderr.writeln('Usage: dart run tool/estimator_loc_nearest_beacon.dart '
        '--log <session.jsonl> [--venue X] [--env prod|dev] [--beacons f.json]');
    exit(2);
  }

  final (jsonl, beaconDb, _) = await loadSession(logPath, opts);

  final beaconBids = {for (final b in beaconDb.values) b.buildingID};
  final warnedBids = <String>{};

  final distances = <double>[];
  var count = 0;
  stdout.writeln('${'time'.padRight(23)} '
      '${'x'.padLeft(6)} ${'y'.padLeft(6)} ${'floor'.padLeft(5)}  '
      '${'bid'.padRight(24)}  ${'nearest'.padRight(12)} '
      '${'bx'.padLeft(6)} ${'by'.padLeft(6)} ${'dist(ft)'.padLeft(8)}');
  for (final line in const LineSplitter().convert(jsonl)) {
    if (!line.contains('"estimatorLoc"')) continue;
    final Object? rec;
    try {
      rec = json.decode(line);
    } on FormatException {
      continue; // a session killed mid-write leaves a torn last line
    }
    if (rec is! Map || rec['type'] != 'estimatorLoc') continue;
    final loc = rec['loc'];
    if (loc is! Map || loc['x'] == null || loc['y'] == null) continue;
    count++;

    final x = (loc['x'] as num).toDouble(), y = (loc['y'] as num).toDouble();
    final floor = (loc['floor'] as num).toInt();
    final bid = '${loc['bid']}';
    final sameBuilding = beaconBids.contains(bid);
    if (!sameBuilding && warnedBids.add(bid)) {
      stderr.writeln('No beacons with building_ID $bid — '
          'matching on floor only.');
    }
    final near = _nearest(beaconDb.values, x, y, floor,
        sameBuilding ? bid : null);
    final feet =
        near == null ? null : near.$2 * _metresPerUnit * _feetPerMetre;
    if (feet != null) distances.add(feet);

    final ts = '${rec['ts']}';
    final tick = feet != null && feet <= _tickFeet ? '  ✓' : '';
    stdout.writeln('${ts.substring(0, 23).replaceFirst('T', ' ').padRight(23)} '
        '${_num(x).padLeft(6)} ${_num(y).padLeft(6)} '
        '${'$floor'.padLeft(5)}  ${bid.padRight(24)}  '
        '${(near?.$1.name ?? '-').padRight(12)} '
        '${'${near?.$1.coordinateX ?? '-'}'.padLeft(6)} '
        '${'${near?.$1.coordinateY ?? '-'}'.padLeft(6)} '
        '${(feet?.toStringAsFixed(1) ?? '-').padLeft(8)}$tick');
  }
  stderr.writeln('$count estimator locations, '
      '${distances.where((d) => d <= _tickFeet).length} within '
      '${_num(_tickFeet)} ft of a beacon (✓).');

  if (distances.isEmpty) return;
  distances.sort();
  final mean = distances.reduce((a, b) => a + b) / distances.length;
  stderr.writeln('Distance to nearest beacon (ft): '
      'mean ${mean.toStringAsFixed(1)}, '
      'median ${distances[distances.length ~/ 2].toStringAsFixed(1)}, '
      'max ${distances.last.toStringAsFixed(1)}');
}

/// The beacon closest to ([x], [y]) on [floor] — of building [bid] too, unless
/// it is null — with its distance in grid units; null when there is none.
(Beacon, double)? _nearest(
    Iterable<Beacon> beacons, double x, double y, int floor, String? bid) {
  (Beacon, double)? best;
  for (final b in beacons) {
    if (b.floor != floor || (bid != null && b.buildingID != bid)) continue;
    if (b.coordinateX == null || b.coordinateY == null) continue;
    final dx = x - b.coordinateX!, dy = y - b.coordinateY!;
    final d = sqrt(dx * dx + dy * dy);
    if (best == null || d < best.$2) best = (b, d);
  }
  return best;
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
