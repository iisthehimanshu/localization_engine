import 'dart:async';
import 'package:flutter/services.dart';
import 'package:localization_engine/src/GPS/GPSBuffer.dart';

import 'location.dart';

/// Handles GPS channel communication and buffering
class GpsScanner {
  static const MethodChannel _methodChannel =
      MethodChannel('localization_engine');
  static const EventChannel _gpsEventChannel =
      EventChannel('gps_scan_stream');

  final GPSBuffer _buffer = GPSBuffer();
  StreamSubscription<dynamic>? _subscription;

  Future<void> start() async {
    await _subscription?.cancel();
    await _methodChannel.invokeMethod('startGpsScan');

    _subscription = _gpsEventChannel.receiveBroadcastStream().listen(
      (data) {
        final map = Map<String, dynamic>.from(data as Map);
        _buffer.add(map['latitude'] as double, map['longitude'] as double);
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
    final pos = _buffer.getRobustPosition();
    if (pos == null || pos.isEmpty) return null;
    return GPSLocation(latitude: pos[0], longitude: pos[1]);
  }

  Stream<Map<String, dynamic>> get rawStream =>
      _gpsEventChannel
          .receiveBroadcastStream()
          .cast<Map<dynamic, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .handleError((Object error) => print('gpsStreamRaw error: $error'));
}
