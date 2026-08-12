import 'dart:async';
import 'package:flutter/services.dart';
import 'package:localization_engine/src/GPS/GPSBuffer.dart';

import 'location.dart';

/// Handles GPS channel communication and buffering
class GpsScanner {
  static const MethodChannel _methodChannel =
      MethodChannel('localization_engine');
  static const EventChannel _gpsEventChannel = EventChannel('gps_scan_stream');

  final GPSBuffer _buffer = GPSBuffer();
  StreamSubscription<dynamic>? _subscription;

  Future<void> start() async {
    await _subscription?.cancel();
    await _methodChannel.invokeMethod('startGpsScan');

    _subscription = _gpsEventChannel.receiveBroadcastStream().listen(
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        final rawTimestamp = map['timestamp'];
        _buffer.addSample(GpsSample(
          latitude: (map['latitude'] as num).toDouble(),
          longitude: (map['longitude'] as num).toDouble(),
          timestamp: rawTimestamp is num
              ? DateTime.fromMillisecondsSinceEpoch(rawTimestamp.toInt())
              : DateTime.now(),
          accuracy: (map['accuracy'] as num?)?.toDouble(),
          speed: (map['speed'] as num?)?.toDouble(),
          bearing: (map['bearing'] as num?)?.toDouble(),
          altitude: (map['altitude'] as num?)?.toDouble(),
        ));
      },
      onError: (Object error) => print('GPS stream error: $error'),
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _methodChannel.invokeMethod('stopGpsScan');
  }

  /// Returns a robust GPS position from the buffer, or null if unavailable.
  GPSLocation? get currentLocation {
    final estimate = _buffer.getRobustEstimate();
    if (estimate == null) return null;
    _buffer.clear();
    return GPSLocation(
      latitude: estimate.latitude,
      longitude: estimate.longitude,
      accuracy: estimate.accuracy,
      sampleCount: estimate.sampleCount,
      confidence: estimate.confidence,
      timeStamp: estimate.timestamp,
    );
  }

  Stream<Map<String, dynamic>> get rawStream => _gpsEventChannel
      .receiveBroadcastStream()
      .cast<Map<dynamic, dynamic>>()
      .map((e) => Map<String, dynamic>.from(e))
      .handleError((Object error) => print('gpsStreamRaw error: $error'));
}
