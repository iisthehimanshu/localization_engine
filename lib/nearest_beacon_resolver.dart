import 'dart:developer' as dev;
import 'dart:math';
import 'package:localization_engine/location.dart';
import 'package:localization_engine/src/localizationAlgorithm/_triangulationlLocalisation.dart';
import 'package:localization_engine/src/network/api/localizationUsingMLModelapi.dart';
import 'package:localization_engine/src/statisticalMode.dart';
import 'initialLocalization.dart';

/// Resolves the nearest beacon from scan data using average RSSI.
class NearestBeaconResolver {
  final InitialLocalization localization;

  const NearestBeaconResolver(this.localization);

  /// Returns a [BeaconPointLocation] for the strongest beacon, or null.
  Future<BeaconPointLocation?> resolve(
      Map<String, List<MapEntry<DateTime, int>>> data,
  {Map<String, dynamic>? apiBeaconMap, List<int>? gt}
      ) async {

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
    // print("data $data");
    // print("modeValues $modeValues");

    data.forEach((beaconId, entries) {
      if (entries.isEmpty) return;
      var beacon = localization.getBeaconDetails(beaconId, apiBeaconMap: apiBeaconMap);
      if(bestFloor != null && beacon != null && beacon.floor != bestFloor) return;
      final avg = modeValues[beaconId] ?? entries.map((e) => e.value).reduce((a, b) => a + b) / entries.length;
      final absAvg = avg.abs();

      if (absAvg < bestAvg) {
        bestAvg = absAvg;
        bestBeacon = beaconId;
      }
    });

    dev.log('nearestBeacon: $bestBeacon @ $bestAvg');

    if (bestBeacon != null){
      final beacon = localization.getBeaconDetails(bestBeacon!, apiBeaconMap: apiBeaconMap);
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
      var sorted = modeValues.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      sorted = sorted.where((s) {
        return localization.getBeaconDetails(
          s.key,
          apiBeaconMap: apiBeaconMap,
        ) != null;
      }).toList();

      if (sorted.length < 3) {
        return null;
      }

      List<MapEntry<String, double>> top3;

      if (bestFloor != null) {
        final filtered = sorted.where((s) {
          final beacon = localization.getBeaconDetails(s.key, apiBeaconMap: apiBeaconMap);
          return beacon != null && beacon.floor == bestFloor;
        }).toList();

        // fallback if less than 3 on that floor
        if (filtered.length >= 4) {
          top3 = selectDiverseBeacons(filtered, apiBeaconMap??localization.apibeaconmap, localization, count: 3, alpha: 0.2);
        } else {
          top3 = selectDiverseBeacons(sorted, apiBeaconMap??localization.apibeaconmap, localization, count: 3, alpha: 0.2);
        }
      } else {
        top3 = selectDiverseBeacons(sorted, apiBeaconMap??localization.apibeaconmap, localization, count: 3, alpha: 0.2);
      }

      String modelResponse = await Localizationusingmlmodelapi().localize(Map.fromEntries(top3));
      final parts = modelResponse.split(',');

      int x = int.parse(parts[1]);
      int y = int.parse(parts[2]);

      dev.log("Top 3 beacons: $top3");
      var topBeacon = localization.getBeaconDetails(top3.first.key, apiBeaconMap: apiBeaconMap);

      var list = top3.map((b)
      {
        var beaconDetails = localization.getBeaconDetails(b.key, apiBeaconMap: apiBeaconMap);
        return Beacon(id: b.key, location: Point2D(beaconDetails!.coordinateX!.toDouble(), beaconDetails.coordinateY!.toDouble()), rssi: b.value);
      }).toList();

      list.forEach((item){
        print("beacon ${item.toString()}");
      });

      dynamic triangulationResult = triangulate(list, distanceScale: 3.28084);
      print(" triangulationResult.estimatedPosition ${ triangulationResult.estimatedPosition.x},${triangulationResult.estimatedPosition.y}");
      return BeaconPointLocation(x: x, y: y, bid: topBeacon!.buildingID!, floor: topBeacon.floor!, latitude: double.parse(topBeacon.properties!.latitude!), longitude: double.parse(topBeacon.properties!.longitude!), beacons: top3.map((b)=>b.key).toList())
        ..tempX = triangulationResult.estimatedPosition.x.toInt()
          ..tempY = triangulationResult.estimatedPosition.y.toInt();
    }
  }

  /// Selects [count] beacons balancing RSSI strength and geometric spread.
  /// [alpha] = 0.0 → pure geometry, 1.0 → pure RSSI. Try 0.4–0.6.
  List<MapEntry<String, double>> selectDiverseBeacons(
      List<MapEntry<String, double>> candidates,
      Map<String, dynamic> apiBeaconMap,
      InitialLocalization localization, {
        int count = 3,
        double alpha = 0.5,
      }) {
    if (candidates.length <= count) return candidates;

    final positions = <String, Point2D>{};
    for (final c in candidates) {
      final details = localization.getBeaconDetails(c.key, apiBeaconMap: apiBeaconMap);
      if (details != null) {
        positions[c.key] = Point2D(
          details.coordinateX!.toDouble(),
          details.coordinateY!.toDouble(),
        );
      }
    }

    final rssiValues = candidates.map((c) => c.value).toList();
    final rssiMin = rssiValues.reduce(min);
    final rssiMax = rssiValues.reduce(max);
    final rssiRange = (rssiMax - rssiMin).abs();

    double normalizedRssi(String key) {
      if (rssiRange < 1e-9) return 1.0;
      final val = candidates.firstWhere((c) => c.key == key).value;
      return (val - rssiMin) / rssiRange;
    }

    final selected = <MapEntry<String, double>>[];
    final remaining = List<MapEntry<String, double>>.from(candidates);

    // Always seed with the strongest beacon
    selected.add(remaining.removeAt(0));

    while (selected.length < count && remaining.isNotEmpty) {
      // Compute each remaining candidate's min distance to any selected beacon
      final minDists = remaining.map((c) {
        final candPos = positions[c.key];
        if (candPos == null) return 0.0;
        double minD = double.infinity;
        for (final sel in selected) {
          final selPos = positions[sel.key];
          if (selPos == null) continue;
          final d = sqrt(pow(candPos.x - selPos.x, 2) + pow(candPos.y - selPos.y, 2));
          if (d < minD) minD = d;
        }
        return minD;
      }).toList();

      // Normalize distances to [0, 1] for this round
      final distMin = minDists.reduce(min);
      final distMax = minDists.reduce(max);
      final distRange = (distMax - distMin).abs();

      double bestScore = -1;
      int bestIdx = 0;

      for (int i = 0; i < remaining.length; i++) {
        final normRssi = normalizedRssi(remaining[i].key);
        final normDist = distRange < 1e-9 ? 1.0 : (minDists[i] - distMin) / distRange;
        final score = alpha * normRssi + (1 - alpha) * (1 - normDist); // prefer closer beacons
        if (score > bestScore) {
          bestScore = score;
          bestIdx = i;
        }
      }

      selected.add(remaining.removeAt(bestIdx));
    }

    return selected;
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