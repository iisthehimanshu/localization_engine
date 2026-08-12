import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/src/GPS/GPSBuffer.dart';

void main() {
  test('rejects poor-accuracy samples and keeps coordinates paired', () {
    final now = DateTime.now();
    final buffer = GPSBuffer(maximumAccuracyMeters: 40)
      ..addSample(GpsSample(
        latitude: 28.545000,
        longitude: 77.192000,
        timestamp: now,
        accuracy: 8,
      ))
      ..addSample(GpsSample(
        latitude: 28.545010,
        longitude: 77.192010,
        timestamp: now,
        accuracy: 7,
      ))
      ..addSample(GpsSample(
        latitude: 28.545020,
        longitude: 77.192020,
        timestamp: now,
        accuracy: 9,
      ))
      ..addSample(GpsSample(
        latitude: 29,
        longitude: 78,
        timestamp: now,
        accuracy: 100,
      ));

    final estimate = buffer.getWindowedRobustEstimate(
      const Duration(seconds: 6),
    );

    expect(estimate, isNotNull);
    expect(estimate!.sampleCount, 3);
    expect(estimate.confidence, 'high');
    expect(estimate.latitude, closeTo(28.54501, 0.00002));
    expect(estimate.longitude, closeTo(77.19201, 0.00002));
  });

  test('accuracy weighting favours the more precise observation', () {
    final now = DateTime.now();
    final buffer = GPSBuffer()
      ..addSample(GpsSample(
        latitude: 28.545,
        longitude: 77.192,
        timestamp: now,
        accuracy: 5,
      ))
      ..addSample(GpsSample(
        latitude: 28.5451,
        longitude: 77.1921,
        timestamp: now,
        accuracy: 25,
      ));

    final estimate = buffer.getRobustEstimate()!;
    expect((estimate.latitude - 28.545).abs(), lessThan(0.00003));
    expect((estimate.longitude - 77.192).abs(), lessThan(0.00003));
  });
}
