import 'dart:collection';
import 'dart:math';
import '../../Point.dart';
import '../network/model/beaconData.dart';

class impericalLocalisation{
  Pt? estimateIntersectionCenter(
      Map<String, List<MapEntry<DateTime, int>>> beaconData,
      HashMap<String, Beacon> apibeaconmap,
      ) {
    // 1️⃣ Find the earliest timestamp in beacon data
    DateTime? earliest;
    for (final entries in beaconData.values) {
      for (final e in entries) {
        if (earliest == null || e.key.isBefore(earliest)) earliest = e.key;
      }
    }
    if (earliest == null) return null;

    final cutoff = earliest.add(const Duration(seconds: 6));

    // 2️⃣ Compute average RSSI for each beacon in the last 6 seconds
    final Map<String, double> avgRssi = {};
    beaconData.forEach((beacon, entries) {
      final recentRssi = entries
          .where((e) => e.key.isBefore(cutoff))
          .map((e) => e.value)
          .toList();
      if (recentRssi.isNotEmpty) {
        avgRssi[beacon] =
            recentRssi.reduce((a, b) => a + b) / recentRssi.length;
      }
    });
    if (avgRssi.isEmpty) return null;

    print("avgRssi $avgRssi");

    // 3️⃣ Select top 3 strongest beacons
    final top3 = avgRssi.entries
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (top3.length < 3) return null;

    final beaconKeys = top3.take(3).map((e) => e.key).toList();

    // 5️⃣ Extract positions of top 3 beacons
    final pos0 = [
      apibeaconmap[beaconKeys[0]]!.coordinateX!,
      apibeaconmap[beaconKeys[0]]!.coordinateY!
    ];
    final pos1 = [
      apibeaconmap[beaconKeys[1]]!.coordinateX!,
      apibeaconmap[beaconKeys[1]]!.coordinateY!
    ];
    final pos2 = [
      apibeaconmap[beaconKeys[2]]!.coordinateX!,
      apibeaconmap[beaconKeys[2]]!.coordinateY!
    ];

    final distanceTopBeacon = rssiToRadius(avgRssi[beaconKeys[0]]!);

    print("distanceTopBeacon $distanceTopBeacon");

    // 6️⃣ Candidate points along directions from top beacon
    List<int> pt1 = moveTowards(pos0, pos1, distanceTopBeacon);
    List<int> pt2 = moveTowards(pos0, pos2, distanceTopBeacon);

    // 7️⃣ Compute derived RSSI values for each candidate
    double computeDerivedRssi(List<int> candidate, List<int> otherPos) {
      double dist = calculateDistance(candidate, otherPos);
      return radiusToRssi(sqrt(dist * dist + 1));
    }

    final derivedPt1B1 = computeDerivedRssi(pt1, pos1);
    final derivedPt1B2 = computeDerivedRssi(pt1, pos2);
    final derivedPt2B1 = computeDerivedRssi(pt2, pos1);
    final derivedPt2B2 = computeDerivedRssi(pt2, pos2);

    // 8️⃣ Compute probability / error for each candidate
    double probPt1 = (derivedPt1B1 - avgRssi[beaconKeys[1]]!).abs() +
        (derivedPt1B2 - avgRssi[beaconKeys[2]]!).abs();
    double probPt2 = (derivedPt2B1 - avgRssi[beaconKeys[1]]!).abs() +
        (derivedPt2B2 - avgRssi[beaconKeys[2]]!).abs();

    // 9️⃣ Return candidate with smaller error
    if (probPt1 < probPt2) {
      return Pt(pt1[0].toDouble(), pt1[1].toDouble(), apibeaconmap[beaconKeys.first]!);
    } else {
      return Pt(pt2[0].toDouble(), pt2[1].toDouble(), apibeaconmap[beaconKeys.first]!);
    }
  }

  double calculateDistance(List<int> p1, List<int> p2) {
    return sqrt(pow(p1[0] - p2[0], 2) + pow(p1[1] - p2[1], 2));
  }

  double rssiToRadius(double rssi, {double txPower = -75}) {
    return pow(10, (txPower - rssi) / 30) * 3.28084; // feet
  }

  double radiusToRssi(double radius, {double txPower = -75}) {
    return txPower - 30 * log(radius / 3.28084) / ln10;
  }

  List<int> moveTowards(List<int> start, List<int> end, double distance) {
    int x1 = start[0];
    int y1 = start[1];
    int x2 = end[0];
    int y2 = end[1];

    int dx = x2 - x1;
    int dy = y2 - y1;
    double length = sqrt(dx * dx + dy * dy);

    if (length == 0) return [x1, y1]; // points are the same

    double ratio = distance / length;
    // Clamp ratio to not overshoot
    if (ratio > 1) ratio = 1;

    double newX = x1 + dx * ratio;
    double newY = y1 + dy * ratio;

    return [newX.toInt(), newY.toInt()];
  }

}