import 'dart:developer';
import 'package:localization_engine/location.dart';
import 'initialLocalization.dart';

/// Resolves the nearest beacon from scan data using average RSSI.
class NearestBeaconResolver {
  final InitialLocalization localization;

  const NearestBeaconResolver(this.localization);

  /// Returns a [BeaconPointLocation] for the strongest beacon, or null.
  BeaconPointLocation? resolve(
    Map<String, List<MapEntry<DateTime, int>>> data,
  ) {
    String? bestBeacon;
    double bestAvg = 90;

    data.forEach((beaconId, entries) {
      if (entries.isEmpty) return;

      final avg = entries.map((e) => e.value).reduce((a, b) => a + b) /
          entries.length;
      final absAvg = avg.abs();

      if (absAvg < bestAvg) {
        bestAvg = absAvg;
        bestBeacon = beaconId;
      }
    });

    log('nearestBeacon: $bestBeacon @ $bestAvg');

    if (bestBeacon == null) return null;

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
  }
}
