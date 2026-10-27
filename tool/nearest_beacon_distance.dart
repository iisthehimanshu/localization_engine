// tool/nearest_beacon_distance.dart
//
// Terminal-only debug harness: replays a recorded session log through
// [BLEPositionEstimator] and, for every position it returned, prints the
// distance to the nearest beacon on the same floor of the same building.
// Nothing here ships in the package.
//
// Run:
//   dart run tool/nearest_beacon_distance.dart --log ~/Downloads/session.jsonl
//   dart run tool/nearest_beacon_distance.dart --log "/Users/himanshu/Downloads/1791551183013-47494095-sensor_nav-AIGHospital-1791550962953_AP3A.240905.015.A2_1791551180458.jsonl"
//
// Options: same as tool/replay_session_positions.dart
//   --venue "X"        venue to fetch beacons for (default: the log's venueName)
//   --env prod|dev     backend to fetch them from (default: prod)
//   --beacons f.json   use a saved beacon JSON array instead of the backend
//   --walking true|false  force one motion profile for the whole replay
//                      (default: follow the session — see replaySessionLog)

import 'dart:io';
import 'dart:math';

import 'package:localization_engine/src/network/model/beaconData.dart';

import 'replay_session_positions.dart';

// Metres per floor-plan grid unit (mirrors Beacon.distanceTo).
const _metresPerUnit = 1.0;

// The distance is measured the way the SDK's relocalization debug panel
// measures it, so the two can be compared row for row: the engine hands the
// SDK `BeaconPointLocation` with x/y rounded to whole grid cells, and
// DirectionHeader.listenToBin measures from those to the nearest beacon on the
// fix's floor.

/// The beacon closest to ([x], [y]) among those on [floor] of building [bid],
/// with its distance in grid units — null when that floor has no beacons.
(Beacon, double)? nearestBeacon(
    Iterable<Beacon> beacons, double x, double y, int floor, String bid) {
  (Beacon, double)? best;
  for (final b in beacons) {
    if (b.floor != floor || b.buildingID != bid) continue;
    if (b.coordinateX == null || b.coordinateY == null) continue;
    final dx = x - b.coordinateX!, dy = y - b.coordinateY!;
    final d = sqrt(dx * dx + dy * dy);
    if (best == null || d < best.$2) best = (b, d);
  }
  return best;
}

Future<void> main(List<String> args) async {
  final opts = parseArgs(args);
  final logPath = opts['log'];
  if (logPath == null) {
    stderr.writeln('Usage: dart run tool/nearest_beacon_distance.dart '
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

  final distances = <double>[];
  stdout.writeln('${'time'.padRight(23)} '
      '${'x'.padLeft(8)} ${'y'.padLeft(8)} ${'floor'.padLeft(5)}  '
      '${'bid'.padRight(24)}  ${'beacon'.padRight(12)} '
      '${'bx'.padLeft(6)} ${'by'.padLeft(6)} ${'dist(m)'.padLeft(8)}');
  for (final p in positions) {
    final ts = (p['ts'] as DateTime).toLocal().toIso8601String();
    final x = (p['x'] as double).roundToDouble(),
        y = (p['y'] as double).roundToDouble();
    final near = nearestBeacon(
        beaconDb.values, x, y, p['floor'] as int, p['bid'] as String);
    final metres = near == null ? null : near.$2 * _metresPerUnit;
    if (metres != null) distances.add(metres);
    stdout.writeln('${ts.substring(0, 23).replaceFirst('T', ' ')} '
        '${x.toStringAsFixed(2).padLeft(8)} ${y.toStringAsFixed(2).padLeft(8)} '
        '${'${p['floor']}'.padLeft(5)}  ${'${p['bid']}'.padRight(24)}  '
        '${(near?.$1.name ?? '-').padRight(12)} '
        '${'${near?.$1.coordinateX ?? '-'}'.padLeft(6)} '
        '${'${near?.$1.coordinateY ?? '-'}'.padLeft(6)} '
        '${(metres?.toStringAsFixed(2) ?? '-').padLeft(8)}');
  }

  if (distances.isEmpty) return;
  distances.sort();
  final mean = distances.reduce((a, b) => a + b) / distances.length;
  stderr.writeln('Distance to nearest beacon (m): '
      'mean ${mean.toStringAsFixed(2)}, '
      'median ${distances[distances.length ~/ 2].toStringAsFixed(2)}, '
      'max ${distances.last.toStringAsFixed(2)}');
}
