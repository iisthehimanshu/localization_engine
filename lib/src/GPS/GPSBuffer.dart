import 'dart:math';

/// One complete native GPS observation.
///
/// Keeping latitude and longitude together prevents robust filtering from
/// accidentally combining coordinates from different source observations.
class GpsSample {
  const GpsSample({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracy,
    this.speed,
    this.bearing,
    this.altitude,
  });

  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? accuracy;
  final double? speed;
  final double? bearing;
  final double? altitude;
}

/// A robust GPS estimate together with the quality evidence used to build it.
class GpsPositionEstimate {
  const GpsPositionEstimate({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.sampleCount,
    required this.timestamp,
    required this.confidence,
  });

  final double latitude;
  final double longitude;
  final double accuracy;
  final int sampleCount;
  final DateTime timestamp;
  final String confidence;

  List<double> get coordinates => <double>[latitude, longitude];
}

class GPSBuffer {
  GPSBuffer({this.maximumAccuracyMeters = 40});

  final double maximumAccuracyMeters;
  final List<GpsSample> _samples = <GpsSample>[];

  /// Backwards-compatible entry point for callers without GPS quality data.
  void add(double lat, double lon, [DateTime? ts]) {
    addSample(GpsSample(
      latitude: lat,
      longitude: lon,
      timestamp: ts ?? DateTime.now(),
    ));
  }

  void addSample(GpsSample sample) {
    if (!sample.latitude.isFinite ||
        !sample.longitude.isFinite ||
        sample.latitude.abs() > 90 ||
        sample.longitude.abs() > 180) {
      return;
    }
    final accuracy = sample.accuracy;
    if (accuracy != null &&
        (!accuracy.isFinite ||
            accuracy <= 0 ||
            accuracy > maximumAccuracyMeters)) {
      return;
    }
    _samples.add(sample);
  }

  void clear() => _samples.clear();

  /// Robust position over all buffered samples. Clears the buffer afterwards.
  List<double>? getRobustPosition() {
    final result = getRobustEstimate();
    clear();
    return result?.coordinates;
  }

  GpsPositionEstimate? getRobustEstimate() => _estimate(_samples);

  /// Robust position over samples received within the last [window].
  List<double>? getWindowedRobustPosition(Duration window) =>
      getWindowedRobustEstimate(window)?.coordinates;

  GpsPositionEstimate? getWindowedRobustEstimate(Duration window) {
    final cutoff = DateTime.now().subtract(window);
    _samples.removeWhere((sample) => sample.timestamp.isBefore(cutoff));
    return _estimate(_samples);
  }

  GpsPositionEstimate? _estimate(List<GpsSample> input) {
    if (input.isEmpty) return null;

    // Establish a robust geographic centre, then reject complete samples by
    // their physical distance from it. Latitude and longitude never separate.
    final medianLatitude = _median(input.map((s) => s.latitude).toList());
    final medianLongitude = _median(input.map((s) => s.longitude).toList());
    final distances = input
        .map((sample) => _distanceMeters(
              sample.latitude,
              sample.longitude,
              medianLatitude,
              medianLongitude,
            ))
        .toList();
    final medianDistance = _median(distances);
    final mad = _median(
      distances.map((distance) => (distance - medianDistance).abs()).toList(),
    );
    // A zero MAD is common for stationary GPS. Keep a modest physical floor so
    // one small quantisation difference does not discard otherwise good fixes.
    final robustRadius = max(5.0, medianDistance + 3 * mad);

    final accepted = <GpsSample>[];
    for (var index = 0; index < input.length; index++) {
      final sample = input[index];
      final accuracyRadius = sample.accuracy ?? 25.0;
      if (distances[index] <= max(robustRadius, accuracyRadius)) {
        accepted.add(sample);
      }
    }
    if (accepted.isEmpty) return null;

    double totalWeight = 0;
    double latitude = 0;
    double longitude = 0;
    double weightedAccuracy = 0;
    for (final sample in accepted) {
      final accuracy = max(sample.accuracy ?? 25.0, 3.0);
      final weight = 1 / (accuracy * accuracy);
      latitude += sample.latitude * weight;
      longitude += sample.longitude * weight;
      weightedAccuracy += accuracy * weight;
      totalWeight += weight;
    }
    final estimatedAccuracy = weightedAccuracy / totalWeight;
    final confidence = accepted.length >= 3 && estimatedAccuracy <= 12
        ? 'high'
        : accepted.length >= 2 && estimatedAccuracy <= 25
            ? 'medium'
            : 'low';

    return GpsPositionEstimate(
      latitude: latitude / totalWeight,
      longitude: longitude / totalWeight,
      accuracy: estimatedAccuracy,
      sampleCount: accepted.length,
      timestamp: accepted
          .map((sample) => sample.timestamp)
          .reduce((a, b) => a.isAfter(b) ? a : b),
      confidence: confidence,
    );
  }

  static double _median(List<double> values) {
    values.sort();
    final middle = values.length ~/ 2;
    if (values.length.isOdd) return values[middle];
    return (values[middle - 1] + values[middle]) / 2;
  }

  static double _distanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    const earthRadiusMeters = 6371000.0;
    final lat1 = latitude1 * pi / 180;
    final lat2 = latitude2 * pi / 180;
    final deltaLatitude = (latitude2 - latitude1) * pi / 180;
    final deltaLongitude = (longitude2 - longitude1) * pi / 180;
    final a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2) +
        cos(lat1) *
            cos(lat2) *
            sin(deltaLongitude / 2) *
            sin(deltaLongitude / 2);
    return earthRadiusMeters * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
