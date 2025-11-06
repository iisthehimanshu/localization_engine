import 'dart:collection';
import 'dart:io';
import 'dart:math';
import '../network/model/beaconData.dart';
import 'initialLocalization.dart';

enum Direction { TopBeaconToSecondBeacon, SecondBeaconToTopBeacon }

class DirectionalLocalisation {
  double lineOfSightTxPower = -75;
  double nonLineOfSightTxPower = -80;

  Future<Pt?> estimateIntersectionCenter(
    Map<String, List<MapEntry<DateTime, int>>> beaconData,
    HashMap<String, Beacon> apibeaconmap,
    double userDirection,
  ) async {
    // beaconData = applyKalmanReturningSame(beaconData);
// 1️⃣ Find the earliest timestamp in Beacon data
    DateTime? last;
    for (final entries in beaconData.values) {
      for (final e in entries) {
        if (last == null || e.key.isAfter(last)) last = e.key;
      }
    }
    if (last == null) return null;

    final cutoff = last.subtract(const Duration(seconds: 6));

// 2️⃣ Compute average RSSI for each Beacon in the last 6 seconds
    final Map<String, double> avgRssi = {};
    beaconData.forEach((Beacon, entries) {
      final recentRssi = entries
          .where((e) => e.key.isAfter(cutoff))
          .map((e) => e.value)
          .toList();
      if (recentRssi.isNotEmpty) {
        avgRssi[Beacon] =
            recentRssi.reduce((a, b) => a + b) / recentRssi.length;
      }
    });
    if (avgRssi.isEmpty) return null;

    print("avgRssi $avgRssi");

// 3️⃣ Select top 3 strongest beacons
    final top3 = avgRssi.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if(top3.isEmpty){
      return null;
    }else if (top3.length == 1){
      Beacon beacon = apibeaconmap[top3.first]!;
      return Pt(beacon.coordinateX!.toDouble(), beacon.coordinateY!.toDouble(), beacon, top3beacons: [beacon]);
    }else if(top3.length == 2){
      top3.add(top3.last);
    }

    final beaconKeys = top3.take(3).map((e) => e.key).toList();

    print("beaconKeys $beaconKeys");

// 5️⃣ Extract positions of top 2 beacons
    final localPos0 = [
      apibeaconmap[beaconKeys[0]]!.coordinateX!,
      apibeaconmap[beaconKeys[0]]!.coordinateY!
    ];
    final globalPos0 = [
      double.parse(apibeaconmap[beaconKeys[0]]!.properties!.latitude!),
      double.parse(apibeaconmap[beaconKeys[0]]!.properties!.longitude!)
    ];
    final localPos1 = [
      apibeaconmap[beaconKeys[1]]!.coordinateX!,
      apibeaconmap[beaconKeys[1]]!.coordinateY!
    ];
    final globalPos1 = [
      double.parse(apibeaconmap[beaconKeys[1]]!.properties!.latitude!),
      double.parse(apibeaconmap[beaconKeys[1]]!.properties!.longitude!)
    ];
    final localPos2 = [
      apibeaconmap[beaconKeys[2]]!.coordinateX!,
      apibeaconmap[beaconKeys[2]]!.coordinateY!
    ];
    final globalPos2 = [
      double.parse(apibeaconmap[beaconKeys[2]]!.properties!.latitude!),
      double.parse(apibeaconmap[beaconKeys[2]]!.properties!.longitude!)
    ];

    if(!checkCollinearity(a: Point(localPos0[0].toDouble(), localPos0[1].toDouble()), b: Point(localPos1[0].toDouble(), localPos1[1].toDouble()), c: Point(localPos2[0].toDouble(), localPos2[1].toDouble()))){
      Beacon beacon = apibeaconmap[beaconKeys.first]!;
      return Pt(beacon.coordinateX!.toDouble(), beacon.coordinateY!.toDouble(), beacon, top3beacons: [beacon]);
    }

    final lineOfSightDistanceTopBeacon = rssiToRadius(avgRssi[beaconKeys[0]]!, txPower: lineOfSightTxPower);
    final nonLineOfSightDistanceTopBeacon = rssiToRadius(avgRssi[beaconKeys[0]]!, txPower: nonLineOfSightTxPower);
    final distanceSecondBeacon;
    final distanceThirdBeacon;

    print("lineOfSightDistanceTopBeacon $lineOfSightDistanceTopBeacon nonLineOfSightDistanceTopBeacon $nonLineOfSightDistanceTopBeacon");

    double angleBetweenTopBeaconAndSecondBeacon = calculateBearing(globalPos0, globalPos1);
    double angleBetweenTopBeaconAndThirdBeacon = calculateBearing(globalPos0, globalPos2);
    print("angleBetweenTopBeaconAndSecondBeacon $angleBetweenTopBeaconAndSecondBeacon angleBetweenTopBeaconAndThirdBeacon $angleBetweenTopBeaconAndThirdBeacon");

    Direction direction = Direction.TopBeaconToSecondBeacon;

    if (normalizeAngle(angleBetweenTopBeaconAndSecondBeacon - 90) < userDirection && normalizeAngle(angleBetweenTopBeaconAndSecondBeacon + 90) > userDirection) {
      direction = Direction.TopBeaconToSecondBeacon;
      distanceSecondBeacon = rssiToRadius(avgRssi[beaconKeys[1]]!, txPower: lineOfSightTxPower);
    } else {
      direction = Direction.SecondBeaconToTopBeacon;
      distanceSecondBeacon = rssiToRadius(avgRssi[beaconKeys[1]]!, txPower: nonLineOfSightTxPower);
    }

    if (normalizeAngle(angleBetweenTopBeaconAndThirdBeacon - 90) < userDirection && normalizeAngle(angleBetweenTopBeaconAndThirdBeacon + 90) > userDirection) {
      distanceThirdBeacon = rssiToRadius(avgRssi[beaconKeys[2]]!, txPower: lineOfSightTxPower);
    } else {
      distanceThirdBeacon = rssiToRadius(avgRssi[beaconKeys[2]]!, txPower: nonLineOfSightTxPower);
    }

    print("direction $direction");

    Point<int> ptBetween;
    Point<int> ptAway;

    if (direction == Direction.TopBeaconToSecondBeacon) {
      ptBetween = moveXY(Beacon: localPos0, directionDeg: normalizeAngle(angleBetweenTopBeaconAndSecondBeacon - 25), distance: nonLineOfSightDistanceTopBeacon);
      ptAway = moveXY(Beacon: localPos0, directionDeg: normalizeAngle(angleBetweenTopBeaconAndSecondBeacon + 180 - 25), distance: lineOfSightDistanceTopBeacon);
    } else {
      ptBetween = moveXY(Beacon: localPos0, directionDeg: normalizeAngle(angleBetweenTopBeaconAndSecondBeacon - 25), distance: lineOfSightDistanceTopBeacon);
      ptAway = moveXY(Beacon: localPos0, directionDeg: normalizeAngle(angleBetweenTopBeaconAndSecondBeacon + 180 - 25), distance: nonLineOfSightDistanceTopBeacon);
    }

// 6️⃣ Candidate points along directions from top Beacon

    print("ptBetween $ptBetween ptAway $ptAway");

// 7️⃣ Compute derived RSSI values for each candidate
    double computeDerivedRssi(Point<int> candidate, List<int> otherPos) {
      double dist = calculateDistance(candidate, otherPos);
      print("candidate $candidate otherPos $otherPos");
      if (direction == Direction.TopBeaconToSecondBeacon) {
        return radiusToRssi(sqrt((dist * dist) + 1),
            txPower: lineOfSightTxPower);
      } else {
        return radiusToRssi(sqrt((dist * dist) + 1),
            txPower: nonLineOfSightTxPower);
      }
    }

    final distancePtBetweenB1 = calculateDistance(ptBetween, localPos1);
    final distancePtAway2B1 = calculateDistance(ptAway, localPos1);

    final distancePtBetweenB2 = calculateDistance(ptBetween, localPos2);
    final distancePtAway2B2 = calculateDistance(ptAway, localPos2);

    print("distancePtBetweenB1 $distancePtBetweenB1 distancePtAway2B1 $distancePtAway2B1 distanceSecondBeacon $distanceSecondBeacon");
    print("distancePtBetweenB1 $distancePtBetweenB2 distancePtAway2B1 $distancePtAway2B2 distanceSecondBeacon $distanceThirdBeacon");

// 8️⃣ Compute probability / error for each candidate
    double probPtBetween = (((distancePtBetweenB1 - distanceSecondBeacon)/(distanceSecondBeacon*distancePtBetweenB1)).abs() + ((distancePtBetweenB2 - distanceThirdBeacon)/(distanceThirdBeacon*distancePtBetweenB2)).abs())/2;
    double probPtAway = (((distancePtAway2B1 - distanceSecondBeacon)/(distanceSecondBeacon*distancePtAway2B1)).abs() + ((distancePtAway2B2 - distanceThirdBeacon)/(distanceThirdBeacon*distancePtAway2B2)).abs())/2;

    print("probPtBetween $probPtBetween probPtAway $probPtAway");
    try{
    await _appendLogToFile(
    beaconData: beaconData,
    userDirection: userDirection,
    probBetween: probPtBetween,
    probAway: probPtAway,
    );
    }catch(e){
      print("Error while saving data $e");
    }
// 9️⃣ Return candidate with smaller error
    List<Beacon> top3Beacons = beaconKeys.map((key)=>apibeaconmap[key]!).toList();
    if (probPtBetween < probPtAway) {
      return Pt(ptBetween.x.toDouble(), ptBetween.y.toDouble(), apibeaconmap[beaconKeys.first]!, top3beacons: top3Beacons);
    } else {
      return Pt(ptAway.x.toDouble(), ptAway.y.toDouble(), apibeaconmap[beaconKeys.first]!, top3beacons: top3Beacons);
    }
  }

  double calculateDistance(Point<int> p1, List<int> p2) {
    return sqrt(pow(p1.x - p2[0], 2) + pow(p1.y - p2[1], 2));
  }

  double normalizeAngle(double angle) {
    if (angle > 360) {
      return angle - 360;
    } else if (angle < 0) {
      return angle + 360;
    } else {
      return angle;
    }
  }

  double rssiToRadius(double rssi, {double txPower = -75}) {
    return pow(10, (txPower - rssi) / 20) * 3.28084; // feet
  }

  double radiusToRssi(double radius, {double txPower = -75}) {
    return txPower - 20 * log(radius / 3.28084) / ln10;
  }

  double calculateBearing(List<double> pointA, List<double> pointB) {
    double toRadians(double degree) {
      return degree * pi / 180.0;
    }

    double lat1 = toRadians(pointA[0]);
    double lon1 = toRadians(pointA[1]);
    double lat2 = toRadians(pointB[0]);
    double lon2 = toRadians(pointB[1]);

    double dLon = lon2 - lon1;

    double y = sin(dLon) * cos(lat2); // Swapped
    double x =
        cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon); // Swapped

    double bearingRadians = atan2(y, x); // Note: atan2(y, x) not atan2(x, y)
    double bearingDegrees = bearingRadians * 180.0 / pi;
    bearingDegrees = (bearingDegrees + 360) % 360;

    return bearingDegrees;
  }

  Point<int> moveXY({
    required List<int> Beacon,
    required double directionDeg,
    required double distance,
  }) {
    final rad = (270 + directionDeg) * pi / 180;
    final nx = Beacon[0] + distance.floor() * cos(rad);
    final ny = Beacon[1] + distance.floor() * sin(rad);
    return Point(nx.round(), ny.round());
  }

  Map<String, List<MapEntry<DateTime, int>>> applyKalmanReturningSame(
    Map<String, List<MapEntry<DateTime, int>>> beaconData,
  ) {
    final result = <String, List<MapEntry<DateTime, int>>>{};

    for (final entry in beaconData.entries) {
      final String beaconId = entry.key;
      final List<MapEntry<DateTime, int>> samples = entry.value
        ..sort((a, b) => a.key.compareTo(b.key)); // ensure time sorted

// init filter with first reading
      final kf = Kalman1D(initialValue: samples.first.value.toDouble());
      final filteredList = <MapEntry<DateTime, int>>[];

      for (final m in samples) {
        final filtered = kf.update(m.value.toDouble());
        filteredList.add(MapEntry(m.key, filtered.round()));
      }

      result[beaconId] = filteredList;
    }

    return result;
  }

  bool checkCollinearity({
    required Point<double> a,
    required Point<double> b,
    required Point<double> c,
    double corridorWidth = 22, // feet
  }) {
    final x1 = a.x, y1 = a.y;
    final x2 = b.x, y2 = b.y;
    final x3 = c.x, y3 = c.y;

    final cross = ((x2 - x1) * (y3 - y1)) -
        ((y2 - y1) * (x3 - x1));

    final base = sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
    if (base == 0) return false; // A and B are same point

    final perpDist = cross.abs() / base;

    return perpDist <= corridorWidth;
  }

  Future<void> _appendLogToFile({
    required Map<String, List<MapEntry<DateTime,int>>> beaconData,
    required double userDirection,
    required double probBetween,
    required double probAway,
  }) async {

    // 2) Proceed to write
    final file = File('/storage/emulated/0/Download/localisation_log.csv');

    if(!await file.exists()){
      await file.writeAsString(
        'timestamp,userDirection,probBetween,probAway,beaconDataJson,Feedback\n',
        mode: FileMode.write,
        flush: true,
      );
    }

    final beaconJson = beaconData.map(
            (k,v)=> MapEntry(
            k,
            v.map((e)=>[e.key.toIso8601String(),e.value]).toList()
        )
    );

    await file.writeAsString(
      '${DateTime.now().toIso8601String()},'
          '"${beaconJson.toString()}",'
          '$userDirection,'
          '$probBetween,'
          '$probAway,',
      mode: FileMode.append,
      flush: true,
    );
  }

}

class Kalman1D {
  double x;
  double p;
  final double q;
  final double r;

  Kalman1D({required double initialValue, this.q = 0.01, this.r = 1.0})
      : x = initialValue,
        p = 1;

  double update(double z) {
    p += q;
    final k = p / (p + r);
    x = x + k * (z - x);
    p = (1 - k) * p;
    return x;
  }
}
