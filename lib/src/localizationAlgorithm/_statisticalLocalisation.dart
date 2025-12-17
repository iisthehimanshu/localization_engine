import 'dart:collection';
import 'dart:math';
import '../../Point.dart';
import '../network/model/beaconData.dart';

class CircleIntersection{
  Pt? estimateIntersectionCenter(
      Map<String, List<MapEntry<DateTime, int>>> beaconData,
      HashMap<String, Beacon> apibeaconmap,
      ) {

    DateTime? earliest;
    for (final entries in beaconData.values) {
      for (final e in entries) {
        if (earliest == null || e.key.isBefore(earliest)) {
          earliest = e.key;
        }
      }
    }
    final cutoff = earliest!.add(const Duration(seconds: 6));


    // Step 1: Average RSSI for each Beacon in last 6 seconds
    final Map<String, double> avgRssi = {};
    beaconData.forEach((beacon, entries) {
      final recent = entries.where((e) => e.key.isBefore(cutoff)).map((e) => e.value).toList();
      if (recent.isNotEmpty) {
        avgRssi[beacon] = recent.reduce((a, b) => a + b) / recent.length;
      }
    });
    if (avgRssi.isEmpty) return null;

    print("avgRssi $avgRssi");

    // Step 2: Get top 3 beacons by average RSSI (higher = stronger)
    final top3 = (avgRssi.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value)))
        .take(3)
        .map((e) => e.key)
        .toList();
    if (top3.length < 3) return null;

    print("top3 $top3");

    // Step 3: Compute mean - 2σ for top 3 beacons
    final Map<String, double> meanMinus0Sigma = {};
    final Map<String, double> meanMinus1Sigma = {};
    final Map<String, double> meanMinus2Sigma = {};
    final Map<String, double> meanMinus3Sigma = {};
    final Map<String, double> meanMinus5Sigma = {};
    for (final b in top3) {
      final vals = beaconData[b]!
          .where((e) => e.key.isBefore(cutoff))
          .map((e) => e.value)
          .toList();
      final mean = avgRssi[b]!;
      final variance = vals.map((v) => pow(v - mean, 2)).reduce((a, b) => a + b) / vals.length;
      final sigma = sqrt(variance);
      meanMinus0Sigma[b] = mean;
      meanMinus1Sigma[b] = mean - 1 * sigma;
      meanMinus2Sigma[b] = mean - 2 * sigma;
      meanMinus3Sigma[b] = mean - 3 * sigma;
      meanMinus5Sigma[b] = mean - 5 * sigma;
    }
    print("meanMinus0Sigma $meanMinus0Sigma");
    print("meanMinus1Sigma $meanMinus1Sigma");
    print("meanMinus2Sigma $meanMinus2Sigma");
    print("meanMinus3Sigma $meanMinus3Sigma");
    print("meanMinus5Sigma $meanMinus5Sigma");

    // Step 4: Convert RSSI radius model (optional: use directly if calibrated)
    // For simplicity, convert RSSI to "distance-like" radius using inverse mapping:
    double rssiToRadius(double rssi) {
      // This is a simple model: stronger RSSI -> smaller radius
      // tweak 'scale' or formula based on your environment calibration
      // const double scale = 0.1;
      return (pow(10, (-70 - rssi) / (10 * 3))*3.28084);
    }

    // double rssiToRadius(double rssi) {
    //   // This is a simple model: stronger RSSI -> smaller radius
    //   // tweak 'scale' or formula based on your environment calibration
    //   const double scale = 0.1;
    //   return pow(10, (-rssi) * scale).toDouble();
    // }
    Map<Beacon, double> beaconRadiusMap = {};
    Map<Beacon, double> beaconRSSIMap = {};
    Point? tryIntersection(Map<String, double> sigmaMap) {
      beaconRadiusMap.clear();
      final centers = <Point>[];
      final radii = <double>[];
      for (final b in top3) {
        final pos = [
          apibeaconmap[b]!.coordinateX!.toDouble(),
          apibeaconmap[b]!.coordinateY!.toDouble()
        ];
        centers.add(Point(pos[0], pos[1]));
        radii.add(rssiToRadius(sigmaMap[b]!));
        beaconRadiusMap[apibeaconmap[b]!] = rssiToRadius(sigmaMap[b]!);
        beaconRSSIMap[apibeaconmap[b]!] = sigmaMap[b]!;
      }
      if (centers.length < 3) return null;
      final result = _findIntersectionCenterOfThreeCircles(centers, radii);
      return result?['center'];
    }

    // Step 5: Try progressively with mean − 1σ, 2σ, then 3σ
    Point? result = tryIntersection(meanMinus0Sigma);
    result ??= tryIntersection(meanMinus1Sigma);
    result ??= tryIntersection(meanMinus2Sigma);
    result ??= tryIntersection(meanMinus3Sigma);
    result ??= tryIntersection(meanMinus5Sigma);
    List<Beacon> top3Beacons = top3.map((key)=>apibeaconmap[key]!).toList();
    if(result == null){
      return null;
    }
    return Pt(x: result.x.toDouble(), y: result.y.toDouble(), beacon: apibeaconmap[top3.first]!, beaconRadiusMap: beaconRadiusMap, beaconRSSIMap: beaconRSSIMap);
  }

// -------------------- GEOMETRY UTILITY --------------------
  Map<String, dynamic>? _findIntersectionCenterOfThreeCircles(
      List<Point> centers,
      List<double> radii, {
        int coarseGrid = 120,
      }) {
    print("centers $centers");
    print("radii $radii");
    double minX = double.infinity, minY = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity;
    for (int i = 0; i < 3; i++) {
      minX = min(minX, centers[i].x - radii[i]);
      minY = min(minY, centers[i].y - radii[i]);
      maxX = max(maxX, centers[i].x + radii[i]);
      maxY = max(maxY, centers[i].y + radii[i]);
    }

    double dist(Point a, Point b) => sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));
    bool insideAll(Point p) {
      for (int i = 0; i < 3; i++) {
        if (dist(p, centers[i]) > radii[i]) return false;
      }
      return true;
    }

    final inside = <Point>[];
    for (int ix = 0; ix < coarseGrid; ix++) {
      final x = minX + (ix / (coarseGrid - 1)) * (maxX - minX);
      for (int iy = 0; iy < coarseGrid; iy++) {
        final y = minY + (iy / (coarseGrid - 1)) * (maxY - minY);
        final p = Point(x, y);
        if (insideAll(p)) inside.add(p);
      }
    }

    if (inside.isEmpty) return null;

    double sx = 0, sy = 0;
    for (final p in inside) {
      sx += p.x;
      sy += p.y;
    }
    final centroid = Point(sx / inside.length, sy / inside.length);

    double weightedMargin(Point p) {
      double score = double.infinity;
      for (int i = 0; i < 3; i++) {
        final d = dist(p, centers[i]);
        final w = 1 / radii[i]; // Inverse weight of radius
        final m = (radii[i] - d) * w; // Weighted margin
        score = min(score, m);
      }
      return score;
    }

    // Start from centroid if inside, otherwise use best grid point
    Point best = insideAll(centroid) ? centroid : inside.reduce((a, b) =>
    weightedMargin(a) > weightedMargin(b) ? a : b);
    double bestScore = weightedMargin(best);
    double step = (maxX - minX + maxY - minY) / 8.0;

    while (step > 1e-4) {
      bool improved = false;
      for (final dx in [-step, 0, step]) {
        for (final dy in [-step, 0, step]) {
          final candidate = Point(best.x + dx, best.y + dy);
          final score = weightedMargin(candidate);
          if (score > bestScore) {
            best = candidate;
            bestScore = score;
            improved = true;
          }
        }
      }
      if (!improved) step /= 2;
    }

    // Verify final result is valid
    if (!insideAll(best)) return null;

    return {'center': best, 'centroid': centroid};
  }
}