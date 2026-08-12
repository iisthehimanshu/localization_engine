import '../localization_mode.dart';

/// Persisted inputs needed to restore localization in a background isolate.
class LocalizationServiceConfiguration {
  const LocalizationServiceConfiguration({
    required this.venueName,
    required this.mode,
    this.baseUrl,
    this.stopAt,
  });

  final String venueName;
  final String? baseUrl;
  final LocalizationMode mode;
  final DateTime? stopAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'venueName': venueName,
        'baseUrl': baseUrl,
        'mode': mode.name,
        'stopAt': stopAt?.millisecondsSinceEpoch,
      };

  factory LocalizationServiceConfiguration.fromJson(
    Map<String, Object?> json,
  ) {
    final venueName = json['venueName'];
    final baseUrl = json['baseUrl'];
    final modeName = json['mode'];
    final stopAtMilliseconds = json['stopAt'];

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
    );
  }
}
