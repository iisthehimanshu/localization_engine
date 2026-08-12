import '../location.dart';
import 'localization_mode.dart';

class LocalizationSourceDecision {
  const LocalizationSourceDecision({
    required this.beaconLocation,
    required this.gpsLocation,
    required this.primarySource,
    required this.confidence,
  });

  final BeaconPointLocation? beaconLocation;
  final GPSLocation? gpsLocation;
  final String? primarySource;
  final String? confidence;
}

/// Selects location sources using both [LocalizationMode] and estimate quality.
class LocalizationSourceArbitrator {
  const LocalizationSourceArbitrator._();

  static LocalizationSourceDecision decide({
    required LocalizationMode mode,
    required BeaconPointLocation? beacon,
    required GPSLocation? gps,
  }) {
    if (mode == LocalizationMode.onlyBle) {
      return LocalizationSourceDecision(
        beaconLocation: beacon,
        gpsLocation: null,
        primarySource: beacon == null ? null : 'ble',
        confidence: beacon?.confidence,
      );
    }
    if (mode == LocalizationMode.onlyGps) {
      return LocalizationSourceDecision(
        beaconLocation: null,
        gpsLocation: gps,
        primarySource: gps == null ? null : 'gps',
        confidence: gps?.confidence,
      );
    }
    if (beacon == null) {
      return LocalizationSourceDecision(
        beaconLocation: null,
        gpsLocation: gps,
        primarySource: gps == null ? null : 'gps',
        confidence: gps?.confidence,
      );
    }
    if (gps == null) {
      return LocalizationSourceDecision(
        beaconLocation: beacon,
        gpsLocation: null,
        primarySource: 'ble',
        confidence: beacon.confidence,
      );
    }

    final bleQuality = _confidenceRank(beacon.confidence);
    final gpsQuality = _confidenceRank(gps.confidence);
    if (beacon.floor != 0 && bleQuality >= 2) {
      return LocalizationSourceDecision(
        beaconLocation: beacon,
        gpsLocation: null,
        primarySource: 'ble',
        confidence: beacon.confidence,
      );
    }
    if (gpsQuality > bleQuality) {
      return LocalizationSourceDecision(
        beaconLocation: beacon,
        gpsLocation: gps,
        primarySource: 'gps',
        confidence: gps.confidence,
      );
    }
    if (gpsQuality == 1 && bleQuality > 1) {
      return LocalizationSourceDecision(
        beaconLocation: beacon,
        gpsLocation: null,
        primarySource: 'ble',
        confidence: beacon.confidence,
      );
    }
    return LocalizationSourceDecision(
      beaconLocation: beacon,
      gpsLocation: gps,
      primarySource: 'ble',
      confidence: beacon.confidence,
    );
  }

  static int _confidenceRank(String? confidence) => switch (confidence) {
        'high' => 3,
        'medium' => 2,
        'low' => 1,
        _ => 0,
      };
}
