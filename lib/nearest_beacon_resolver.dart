import 'dart:developer';
import 'package:localization_engine/location.dart';
import 'package:localization_engine/src/localizationAlgorithm/_triangulationlLocalisation.dart';
import 'package:localization_engine/src/statisticalMode.dart';
import 'initialLocalization.dart';

/// Resolves the nearest beacon from scan data using average RSSI.
class NearestBeaconResolver {
  final InitialLocalization localization;

  const NearestBeaconResolver(this.localization);

  /// Returns a [BeaconPointLocation] for the strongest beacon, or null.
  BeaconPointLocation? resolve(
      Map<String, List<MapEntry<DateTime, int>>> data,
      ) {

    int? bestFloor;

    if(localization.apibeaconmap.isNotEmpty){
      final result = analyseTopBeaconsCircleProximity(
        data,
        localization.apibeaconmap.values.toList(),
      )..removeWhere((r) => r.result == null);
      if(result.isNotEmpty){
        bestFloor = getBestFloor(result);
      }
    }

    String? bestBeacon;
    double bestAvg = 90; // targeting good beacons only having rssi better than -90

    var modeValues = filterByBinsAndAverage(data);

    data.forEach((beaconId, entries) {
      if (entries.isEmpty) return;
      var beacon = localization.getBeaconDetails(beaconId);
      if(bestFloor != null && beacon != null && beacon.floor != bestFloor) return;
      final avg = modeValues[beaconId] ?? entries.map((e) => e.value).reduce((a, b) => a + b) / entries.length;
      final absAvg = avg.abs();

      if (absAvg < bestAvg) {
        bestAvg = absAvg;
        bestBeacon = beaconId;
      }
    });

    log('nearestBeacon: $bestBeacon @ $bestAvg');

    if (bestBeacon != null){
      final beacon = localization.getBeaconDetails(bestBeacon!);
      if (beacon == null) return null;

      return BeaconPointLocation(
        x: beacon.coordinateX!,
        y: beacon.coordinateY!,
        bid: beacon.buildingID!,
        floor: beacon.floor!,
        latitude: double.parse(beacon.properties!.latitude!),
        longitude: double.parse(beacon.properties!.longitude!),
        beacons: [bestBeacon!],
      );
    }else{

      // Sort by nearest (highest RSSI assumed better)
      final sorted = modeValues.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      if (sorted.length < 3) {
        return null;
      }

      List<MapEntry<String, double>> top3;

      if (bestFloor != null) {
        final filtered = sorted.where((s) {
          final beacon = localization.getBeaconDetails(s.key);
          return beacon != null && beacon.floor == bestFloor;
        }).toList();

        // fallback if less than 3 on that floor
        if (filtered.length >= 3) {
          top3 = filtered.take(3).toList();
        } else {
          top3 = sorted.take(3).toList(); // fallback to global top 3
        }
      } else {
        top3 = sorted.take(3).toList();
      }


      log("Top 3 beacons: $top3");
      var topBeacon = localization.getBeaconDetails(top3.first.key);

      var list = top3.map((b)
      {
        var beaconDetails = localization.getBeaconDetails(b.key);
        return Beacon(id: b.key, location: Point2D(beaconDetails!.coordinateX!.toDouble(), beaconDetails.coordinateY!.toDouble()), rssi: b.value);
      }).toList();

      list.forEach((item){
        print("beacon ${item.toString()}");
      });

      TriangulationResult triangulationResult = triangulate(list);
      print(" triangulationResult.estimatedPosition.x ${ triangulationResult.estimatedPosition.x}");
      return BeaconPointLocation(x: triangulationResult.estimatedPosition.x.toInt(), y: triangulationResult.estimatedPosition.y.toInt(), bid: topBeacon!.buildingID!, floor: topBeacon.floor!, latitude: double.parse(topBeacon.properties!.latitude!), longitude: double.parse(topBeacon.properties!.longitude!), beacons: top3.map((b)=>b.key).toList());
    }
  }

  int getBestFloor(List<dynamic> result) {
    // ---- Find top 2 by RSSI (no full sort) ----
    var top1 = result[0];
    var top2 = result.length > 1 ? result[1] : result[0];

    if (top2.result!.beacon1ModeRssi > top1.result!.beacon1ModeRssi) {
      final temp = top1;
      top1 = top2;
      top2 = temp;
    }

    for (int i = 2; i < result.length; i++) {
      final r = result[i];
      final rssi = r.result!.beacon1ModeRssi;

      if (rssi > top1.result!.beacon1ModeRssi) {
        top2 = top1;
        top1 = r;
      } else if (rssi > top2.result!.beacon1ModeRssi) {
        top2 = r;
      }
    }

    final rssi1 = top1.result!.beacon1ModeRssi;
    final rssi2 = top2.result!.beacon1ModeRssi;

    // ---- Rule 1: RSSI dominance ----
    if ((rssi1 - rssi2).abs() >= 5 && top1.floor < top2.floor) {
      return top1.floor;
    }

    // ---- Find top 2 by distance ----
    var d1 = result[0];
    var d2 = result.length > 1 ? result[1] : result[0];

    if (d2.result!.averageDistanceToCircles <
        d1.result!.averageDistanceToCircles) {
      final temp = d1;
      d1 = d2;
      d2 = temp;
    }

    for (int i = 2; i < result.length; i++) {
      final r = result[i];
      final dist = r.result!.averageDistanceToCircles;

      if (dist < d1.result!.averageDistanceToCircles) {
        d2 = d1;
        d1 = r;
      } else if (dist < d2.result!.averageDistanceToCircles) {
        d2 = r;
      }
    }

    final dist1 = d1.result!.averageDistanceToCircles;
    final dist2 = d2.result!.averageDistanceToCircles;

    // ---- Rule 2: Distance proximity ----
    if ((dist1 - dist2).abs() <= 1) {
      return d1.floor < d2.floor ? d1.floor : d2.floor;
    }

    return d1.floor;
  }

}