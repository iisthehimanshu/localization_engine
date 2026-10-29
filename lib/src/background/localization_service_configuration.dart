import '../localization_mode.dart';

/// Persisted inputs needed to restore localization in a background isolate.
class LocalizationServiceConfiguration {
  const LocalizationServiceConfiguration({
    required this.venueName,
    required this.mode,
    this.baseUrl,
    this.stopAt,
    this.surroundingDeviceScanInterval = const Duration(seconds: 10),
    this.beacons,
  });

  final String venueName;
  final String? baseUrl;
  final LocalizationMode mode;
  final DateTime? stopAt;
  final Duration surroundingDeviceScanInterval;

  /// The venue's beacons as the backend sent them (`/secured/venue/beacons`),
  /// loaded in the main isolate. The background isolate uses these and never
  /// opens the beacon cache, which only the main isolate may touch. Null
  /// when the mode doesn't use BLE.
  final List<Map<String, dynamic>>? beacons;

  Map<String, Object?> toJson() => <String, Object?>{
        'venueName': venueName,
        'baseUrl': baseUrl,
        'mode': mode.name,
        'stopAt': stopAt?.millisecondsSinceEpoch,
        'surroundingDeviceScanIntervalMs':
            surroundingDeviceScanInterval.inMilliseconds,
        'beacons': beacons,
      };

  factory LocalizationServiceConfiguration.fromJson(
    Map<String, Object?> json,
  ) {
    final venueName = json['venueName'];
    final baseUrl = json['baseUrl'];
    final modeName = json['mode'];
    final stopAtMilliseconds = json['stopAt'];
    final surroundingIntervalMilliseconds =
        json['surroundingDeviceScanIntervalMs'] ?? 10000;
    final beacons = json['beacons'];

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
    if (surroundingIntervalMilliseconds is! int ||
        surroundingIntervalMilliseconds <= 0) {
      throw const FormatException(
        'surroundingDeviceScanIntervalMs must be a positive integer.',
      );
    }

    if (beacons != null &&
        (beacons is! List || beacons.any((b) => b is! Map))) {
      throw const FormatException('beacons must be a list of objects or null.');
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
      surroundingDeviceScanInterval:
          Duration(milliseconds: surroundingIntervalMilliseconds),
      beacons: beacons == null
          ? null
          : [for (final b in beacons as List) Map<String, dynamic>.from(b as Map)],
    );
  }
}
