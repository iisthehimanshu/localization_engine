import 'dart:math';
import 'network/model/beaconData.dart';
import 'localizationAlgorithm/_triangulationlLocalisation.dart' as trialteration;

Map<String, double> filterByBinsAndAverage(
    Map<String, List<MapEntry<DateTime, int>>> data,
    ) {
  const int binSize = 4; // ±2 from center
  final result = <String, double>{};

  data.forEach((beaconId, entries) {
    if (entries.isEmpty) return;

    // Step 1: Calculate mean RSSI
    final mean = entries.map((e) => e.value).reduce((a, b) => a + b) /
        entries.length;

    // Step 2: Find min/max to know how far bins need to expand
    final minVal = entries.map((e) => e.value).reduce((a, b) => a < b ? a : b);
    final maxVal = entries.map((e) => e.value).reduce((a, b) => a > b ? a : b);

    // Step 3: Calculate how many bins needed on each side
    final binsLeft  = ((mean - binSize / 2 - minVal) / binSize).ceil();
    final binsRight = ((maxVal - mean - binSize / 2) / binSize).ceil();

    // Step 4: Build bins and fill with matching entries
    final bins = <int, List<int>>{};

    for (int i = -binsLeft; i <= binsRight + 1; i++) {
      final binStart = (mean - binSize / 2) + (i * binSize);
      final binEnd   = binStart + binSize;

      final binValues = entries
          .where((e) => e.value >= binStart && e.value < binEnd)
          .map((e) => e.value)
          .toList();

      if (binValues.isNotEmpty) {
        bins[i] = binValues;
      }
    }

    // Step 5: Find the bin with the most values
    final densestBin = bins.entries.reduce(
          (a, b) => a.value.length >= b.value.length ? a : b,
    );

    // Step 6: Average the values in the densest bin
    final densestAvg = densestBin.value.reduce((a, b) => a + b) /
        densestBin.value.length;

    // print('Beacon $beaconId | mean: $mean | densest bin: ${densestBin.key} '
    //     '(${densestBin.value.length} values) | avg: $densestAvg');

    result[beaconId] = densestAvg;
  });

  return result;
}

// ─────────────────────────────────────────────
// RSSI → Distance conversion
//
// Uses the Log-Distance Path Loss model:
//   distance = 10 ^ ((txPower - rssi) / (10 * pathLossExponent))
//
//   txPower          : RSSI at 1 metre (typically -59 dBm for BLE)
//   pathLossExponent : environment constant
//                      2.0  → free space
//                      2.7  → open indoor (office/corridor)  ← default
//                      3.5  → obstructed indoor (walls/furniture)
// ─────────────────────────────────────────────
double rssiToDistance(
    String name,
    double rssi, {
      double txPower          = -59.0,
      double pathLossExponent = 2.7,
    }) {
  if (rssi == 0) return -1.0; // invalid reading
  List<String> names = [
    "IW26020521",
    "IW26020522",
    "IW26020523",
    "IW26020524",
    "IW26020525",
    "IW26020526",
    "IW26020527",
    "IW26020528",
    "IW26020529",
    "IW26020530",
    "IW26020531",
    "IW26020532",
    "IW26020533",
    "IW26020534",
    "IW26020535",
    "IW26020536",
    "IW26020537",
    "IW26020538",
    "IW26020539",
    "IW26020540",
  ];
  if(names.contains(name)){
    txPower = -65;
  }
  return pow(10.0, (txPower - rssi) / (10.0 * pathLossExponent)).toDouble();
}

// ─────────────────────────────────────────────
// Per-floor result container
// ─────────────────────────────────────────────

/// Result for a single floor's top-3 beacon analysis.
class BeaconCircleProximityResult {
  /// Floor number this result belongs to.
  final int floor;

  /// The three beacons chosen on this floor, ordered strongest → weakest.
  final Beacon beacon1;
  final Beacon beacon2;
  final Beacon beacon3;

  /// Statistical-mode RSSI for each beacon.
  final double beacon1ModeRssi;
  final double beacon2ModeRssi;
  final double beacon3ModeRssi;

  /// Estimated distance from the scanning device to each beacon (metres),
  /// derived from the mode RSSI via the path-loss model.
  final double beacon1Distance;
  final double beacon2Distance;
  final double beacon3Distance;

  /// Radii of the circles drawn around beacon-2 and beacon-3.
  /// Each radius equals the RSSI-derived device-to-beacon distance.
  final double beacon2Radius;
  final double beacon3Radius;

  /// Euclidean distance between beacon-1 and beacon-2 using real coordinates.
  final double b1ToB2CentreDistance;

  /// Euclidean distance between beacon-1 and beacon-3 using real coordinates.
  final double b1ToB3CentreDistance;

  /// Distance from beacon-1 to the nearest edge of beacon-2's circle.
  ///   = max(0,  euclidean(b1, b2)  −  radius2)
  /// Clamped to 0 when beacon-1 lies inside the circle.
  final double beacon1ToCircle2EdgeDistance;

  /// Distance from beacon-1 to the nearest edge of beacon-3's circle.
  ///   = max(0,  euclidean(b1, b3)  −  radius3)
  final double beacon1ToCircle3EdgeDistance;

  /// Simple average of the two edge-distances above.
  final double averageDistanceToCircles;

  final double? locationError;

  final trialteration.Point2D? estimateLocation;

  final double? b1Dist;
  final double? b2Dist;
  final double? b3Dist;

  const BeaconCircleProximityResult({
    required this.floor,
    required this.beacon1,
    required this.beacon2,
    required this.beacon3,
    required this.beacon1ModeRssi,
    required this.beacon2ModeRssi,
    required this.beacon3ModeRssi,
    required this.beacon1Distance,
    required this.beacon2Distance,
    required this.beacon3Distance,
    required this.beacon2Radius,
    required this.beacon3Radius,
    required this.b1ToB2CentreDistance,
    required this.b1ToB3CentreDistance,
    required this.beacon1ToCircle2EdgeDistance,
    required this.beacon1ToCircle3EdgeDistance,
    required this.averageDistanceToCircles,
    required this.locationError,
    required this.estimateLocation,
    required this.b1Dist,
    required this.b2Dist,
    required this.b3Dist
  });

  @override
  String toString() => '''
BeaconCircleProximityResult [Floor $floor] {
  Top-3 beacons (strongest → weakest):
    1. ${beacon1.name}  (${beacon1.coordinateX}, ${beacon1.coordinateY})  |  mode RSSI: ${beacon1ModeRssi.toStringAsFixed(2)} dBm  |  RSSI distance: ${beacon1Distance.toStringAsFixed(2)} m                                                          | b1Dist: $b1Dist
    2. ${beacon2.name}  (${beacon2.coordinateX}, ${beacon2.coordinateY})  |  mode RSSI: ${beacon2ModeRssi.toStringAsFixed(2)} dBm  |  RSSI distance: ${beacon2Distance.toStringAsFixed(2)} m  |  circle radius: ${beacon2Radius.toStringAsFixed(2)} m | b2Dist: $b2Dist
    3. ${beacon3.name}  (${beacon3.coordinateX}, ${beacon3.coordinateY})  |  mode RSSI: ${beacon3ModeRssi.toStringAsFixed(2)} dBm  |  RSSI distance: ${beacon3Distance.toStringAsFixed(2)} m  |  circle radius: ${beacon3Radius.toStringAsFixed(2)} m | b3Dist: $b3Dist
 
  Beacon-1 → centre of Beacon-2 (Euclidean) : ${b1ToB2CentreDistance.toStringAsFixed(3)} m
  Beacon-1 → centre of Beacon-3 (Euclidean) : ${b1ToB3CentreDistance.toStringAsFixed(3)} m
 
  Beacon-1 → edge of Circle-2  : ${beacon1ToCircle2EdgeDistance.toStringAsFixed(3)} m
  Beacon-1 → edge of Circle-3  : ${beacon1ToCircle3EdgeDistance.toStringAsFixed(3)} m
  Average distance to circles   : ${averageDistanceToCircles.toStringAsFixed(3)} m
  LocationError : $locationError
}''';
}

// ─────────────────────────────────────────────
// Floor-level wrapper
// ─────────────────────────────────────────────

/// Holds the analysis result for one floor.
/// [result] is `null` when the floor had fewer than 3 scanned beacons.
class FloorProximityResult {
  final int                          floor;
  final BeaconCircleProximityResult? result;

  const FloorProximityResult({
    required this.floor,
    required this.result,
  });

  @override
  String toString() => result != null
      ? result.toString()
      : 'Floor $floor: insufficient beacons (need >= 3).';
}

// ─────────────────────────────────────────────
// Internal single-floor helper
// ─────────────────────────────────────────────

BeaconCircleProximityResult? _analyseFloor(
    int                                        floor,
    Map<String, List<MapEntry<DateTime, int>>> floorScanData,
    List<Beacon>                               floorBeacons,
    {
      List<int>? location,
      required double txPower,
      required double pathLossExponent,
    }) {
  // Step 1 — statistical-mode RSSI for every beacon on this floor.
  final modeRssiMap = filterByBinsAndAverage(floorScanData);

  if (modeRssiMap.length < 3) {
    // print('Floor $floor: need >= 3 beacons, got ${modeRssiMap.length}. Skipping.');
    return null;
  }

  // Step 2 — sort descending by RSSI, keep top 3.
  final sorted = modeRssiMap.entries.toList()
    ..sort((a, b) =>rssiToDistance(a.key, a.value, txPower: txPower, pathLossExponent: pathLossExponent).compareTo(rssiToDistance(b.key, b.value, txPower: txPower, pathLossExponent: pathLossExponent)));

  final top3 = sorted.take(3).toList();

  // Step 3 — resolve beacon names to Beacon objects.
  final beaconMap = {for (final b in floorBeacons) b.name: b};

  Beacon? resolve(String name) {
    final b = beaconMap[name];
    if (b == null) {
      // print('Floor $floor: beacon "$name" not found in beaconList.');
    }
    return b;
  }

  final b1 = resolve(top3[0].key);
  final b2 = resolve(top3[1].key);
  final b3 = resolve(top3[2].key);

  if (b1 == null || b2 == null || b3 == null) return null;

  final b1Rssi = top3[0].value;
  final b2Rssi = top3[1].value;
  final b3Rssi = top3[2].value;

  // Step 4 — RSSI → estimated distance.
  final d1 = rssiToDistance(top3[0].key, b1Rssi, txPower: txPower, pathLossExponent: pathLossExponent);
  final d2 = rssiToDistance(top3[1].key, b2Rssi, txPower: txPower, pathLossExponent: pathLossExponent);
  final d3 = rssiToDistance(top3[2].key, b3Rssi, txPower: txPower, pathLossExponent: pathLossExponent);

  var b1Dist;
  var b2Dist;
  var b3Dist;

  // Step 5 — circle radii (= RSSI-derived distance for beacons 2 & 3).
  final radius2 = d2;
  final radius3 = d3;

  // Step 6 — real Euclidean distances between beacon centres.
  final centreDistB1B2 = b1.distanceTo(b2);
  final centreDistB1B3 = b1.distanceTo(b3);

  // Step 7 — distance from beacon-1 to the nearest edge of each circle.
  //
  //   edge_dist = max(0,  centre_dist(b1, bN)  −  radiusN)
  //
  //   Positive → b1 is outside the circle; value is the gap to the edge.
  //   Zero     → b1 is on the circumference or inside the circle.
  final distB1ToCircle2Edge = (centreDistB1B2 - radius2).abs();
  final distB1ToCircle3Edge = (centreDistB1B3 - radius3).abs();

  // Step 8 — average of the two edge-distances.
  final avgDist = (distB1ToCircle2Edge + distB1ToCircle3Edge + d1) / 3.0;

  double? locationError;
  trialteration.Point2D? estimatedLocation;
  if(location != null){
    var list = top3.map((b){
      Beacon beacon = resolve(b.key)!;
      return trialteration.Beacon(
          id: b.key, location: trialteration.Point2D(beacon.coordinateX!.toDouble(), beacon.coordinateY!.toDouble()), rssi: b.value);
    });
    trialteration.TriangulationResult triangulateLocation = trialteration.triangulate(list.toList(), txPower: txPower, pathLossExponent: pathLossExponent, distanceScale: 3.28084);
    estimatedLocation = triangulateLocation.estimatedPosition;
    locationError = sqrt(pow((location[0]-estimatedLocation.x), 2) + pow((location[1]-estimatedLocation.y), 2)) * 0.3048;

    b1Dist = sqrt(pow((location[0]-b1.coordinateX!), 2) + pow((location[1]-b1.coordinateY!), 2)) * 0.3048;
    b2Dist = sqrt(pow((location[0]-b2.coordinateX!), 2) + pow((location[1]-b2.coordinateY!), 2)) * 0.3048;
    b3Dist = sqrt(pow((location[0]-b3.coordinateX!), 2) + pow((location[1]-b3.coordinateY!), 2)) * 0.3048;
  }


  final result = BeaconCircleProximityResult(
    floor:           floor,
    beacon1:         b1,
    beacon2:         b2,
    beacon3:         b3,
    beacon1ModeRssi: b1Rssi,
    beacon2ModeRssi: b2Rssi,
    beacon3ModeRssi: b3Rssi,
    beacon1Distance: d1,
    beacon2Distance: d2,
    beacon3Distance: d3,
    beacon2Radius:   radius2,
    beacon3Radius:   radius3,
    b1ToB2CentreDistance:         centreDistB1B2,
    b1ToB3CentreDistance:         centreDistB1B3,
    beacon1ToCircle2EdgeDistance: distB1ToCircle2Edge,
    beacon1ToCircle3EdgeDistance: distB1ToCircle3Edge,
    averageDistanceToCircles:     avgDist,
    locationError: locationError,
    estimateLocation: estimatedLocation,
    b1Dist: b1Dist,
    b2Dist: b2Dist,
    b3Dist: b3Dist,
  );

  return result;
}

// ─────────────────────────────────────────────
// Public method
// ─────────────────────────────────────────────

/// Segregates [beaconList] and [scannedBeaconData] by [Beacon.floor], then
/// runs the full top-3 / circle-proximity analysis **independently per floor**.
///
/// Returns one [FloorProximityResult] per floor found in [beaconList],
/// sorted by floor number ascending.  Floors with fewer than 3 scanned
/// beacons produce a [FloorProximityResult] whose [result] field is `null`.
///
/// [txPower] and [pathLossExponent] tune the path-loss model.
List<FloorProximityResult> analyseTopBeaconsCircleProximity(
    Map<String, List<MapEntry<DateTime, int>>> scannedBeaconData,
    List<Beacon> beaconList,
    {
      List<int>? location,
      double txPower          = -70.0,
      double pathLossExponent = 1.8,
    }) {
  // ── Step A: group beacons by floor ────────────────────────────────────
  final beaconsByFloor = <int, List<Beacon>>{};
  for (final beacon in beaconList) {
    beaconsByFloor.putIfAbsent(beacon.floor!, () => []).add(beacon);
  }

  // ── Step B: iterate floors in ascending order ──────────────────────────
  final floors = beaconsByFloor.keys.toList()..sort();

  return floors.map((floor) {
    final floorBeacons = beaconsByFloor[floor]!;

    // ── Step C: filter scan data to only this floor's beacon names ───────
    final floorNames    = {for (final b in floorBeacons) b.name};
    final floorScanData = Map.fromEntries(
      scannedBeaconData.entries.where((e) => floorNames.contains(e.key)),
    );

    // ── Step D: run single-floor analysis ────────────────────────────────
    final result = _analyseFloor(
      floor,
      floorScanData,
      floorBeacons,
      txPower:          txPower,
      pathLossExponent: pathLossExponent,
      location: location
    );

    return FloorProximityResult(floor: floor, result: result);
  }).toList();
}