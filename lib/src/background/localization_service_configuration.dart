import '../localization_mode.dart';
import '../localizationAlgorithm/ble_position_estimator.dart';

/// Persisted inputs needed to restore localization in a background isolate.
class LocalizationServiceConfiguration {
  const LocalizationServiceConfiguration({
    required this.venueName,
    required this.mode,
    this.baseUrl,
    this.stopAt,
    this.beaconCalibrations = const <String, BeaconSignalCalibration>{},
    this.pixelsPerMeterByFloor = const <String, double>{},
    this.geoTransformsByFloor = const <String, FloorGeoTransform>{},
  });

  final String venueName;
  final String? baseUrl;
  final LocalizationMode mode;
  final DateTime? stopAt;
  final Map<String, BeaconSignalCalibration> beaconCalibrations;
  final Map<String, double> pixelsPerMeterByFloor;
  final Map<String, FloorGeoTransform> geoTransformsByFloor;

  Map<String, Object?> toJson() => <String, Object?>{
        'venueName': venueName,
        'baseUrl': baseUrl,
        'mode': mode.name,
        'stopAt': stopAt?.millisecondsSinceEpoch,
        'beaconCalibrations': <String, Object?>{
          for (final entry in beaconCalibrations.entries)
            entry.key: <String, Object?>{
              'rssiOffset': entry.value.rssiOffset,
              'reliability': entry.value.reliability,
            },
        },
        'pixelsPerMeterByFloor': pixelsPerMeterByFloor,
        'geoTransformsByFloor': <String, Object?>{
          for (final entry in geoTransformsByFloor.entries)
            entry.key: <String, Object?>{
              'latitudeOrigin': entry.value.latitudeOrigin,
              'longitudeOrigin': entry.value.longitudeOrigin,
              'latitudePerPixelX': entry.value.latitudePerPixelX,
              'latitudePerPixelY': entry.value.latitudePerPixelY,
              'longitudePerPixelX': entry.value.longitudePerPixelX,
              'longitudePerPixelY': entry.value.longitudePerPixelY,
            },
        },
      };

  factory LocalizationServiceConfiguration.fromJson(
    Map<String, Object?> json,
  ) {
    final venueName = json['venueName'];
    final baseUrl = json['baseUrl'];
    final modeName = json['mode'];
    final stopAtMilliseconds = json['stopAt'];
    final beaconCalibrations = _parseBeaconCalibrations(
      json['beaconCalibrations'],
    );
    final pixelsPerMeterByFloor = _parseDoubleMap(
      json['pixelsPerMeterByFloor'],
      'pixelsPerMeterByFloor',
    );
    final geoTransformsByFloor = _parseGeoTransforms(
      json['geoTransformsByFloor'],
    );

    if (venueName is! String || venueName.trim().isEmpty) {
      throw const FormatException('venueName must be a non-empty string.');
    }
    if (baseUrl != null && baseUrl is! String) {
      throw const FormatException('baseUrl must be a string or null.');
    }
    if (modeName is! String) {
      throw const FormatException('mode must be a string.');
    }
    if (stopAtMilliseconds != null && stopAtMilliseconds is! int) {
      throw const FormatException('stopAt must be an integer or null.');
    }

    final mode = LocalizationMode.values.where(
      (candidate) => candidate.name == modeName,
    );
    if (mode.isEmpty) {
      throw FormatException('Unknown localization mode: $modeName.');
    }

    return LocalizationServiceConfiguration(
      venueName: venueName,
      baseUrl: baseUrl as String?,
      mode: mode.single,
      stopAt: stopAtMilliseconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(stopAtMilliseconds as int),
      beaconCalibrations: beaconCalibrations,
      pixelsPerMeterByFloor: pixelsPerMeterByFloor,
      geoTransformsByFloor: geoTransformsByFloor,
    );
  }

  static Map<String, BeaconSignalCalibration> _parseBeaconCalibrations(
    Object? raw,
  ) {
    if (raw == null) return const <String, BeaconSignalCalibration>{};
    if (raw is! Map) {
      throw const FormatException('beaconCalibrations must be a map.');
    }
    return <String, BeaconSignalCalibration>{
      for (final entry in raw.entries)
        entry.key.toString(): _parseBeaconCalibration(entry.value),
    };
  }

  static BeaconSignalCalibration _parseBeaconCalibration(Object? raw) {
    if (raw is! Map ||
        raw['rssiOffset'] is! num ||
        raw['reliability'] is! num) {
      throw const FormatException('Invalid beacon calibration.');
    }
    return BeaconSignalCalibration(
      rssiOffset: (raw['rssiOffset'] as num).toDouble(),
      reliability: (raw['reliability'] as num).toDouble(),
    );
  }

  static Map<String, double> _parseDoubleMap(Object? raw, String field) {
    if (raw == null) return const <String, double>{};
    if (raw is! Map || raw.values.any((value) => value is! num)) {
      throw FormatException('$field must contain numeric values.');
    }
    return <String, double>{
      for (final entry in raw.entries)
        entry.key.toString(): (entry.value as num).toDouble(),
    };
  }

  static Map<String, FloorGeoTransform> _parseGeoTransforms(Object? raw) {
    if (raw == null) return const <String, FloorGeoTransform>{};
    if (raw is! Map) {
      throw const FormatException('geoTransformsByFloor must be a map.');
    }
    return <String, FloorGeoTransform>{
      for (final entry in raw.entries)
        entry.key.toString(): _parseGeoTransform(entry.value),
    };
  }

  static FloorGeoTransform _parseGeoTransform(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid geo transform.');
    double value(String key) {
      final candidate = raw[key];
      if (candidate is! num) {
        throw FormatException('Invalid geo transform field: $key.');
      }
      return candidate.toDouble();
    }

    return FloorGeoTransform(
      latitudeOrigin: value('latitudeOrigin'),
      longitudeOrigin: value('longitudeOrigin'),
      latitudePerPixelX: value('latitudePerPixelX'),
      latitudePerPixelY: value('latitudePerPixelY'),
      longitudePerPixelX: value('longitudePerPixelX'),
      longitudePerPixelY: value('longitudePerPixelY'),
    );
  }
}
