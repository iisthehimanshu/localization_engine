import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'scan_source.dart';

/// [ScanSource] for the page opened in a plain browser, with no host app.
///
/// Reached from a QR code or a desktop, where there is no way to scan for
/// beacons: browsers expose no BLE advertisement API, and Web Bluetooth is a
/// pairing API, not a scanning one. So this serves GPS only, and the engine
/// runs in its outdoor-capable mode with no indoor fix.
///
/// It exists so the same URL works everywhere rather than showing a dead page
/// to anyone outside the app.
class BrowserGeolocationScanSource implements ScanSource {
  final _gpsFixes = StreamController<Map<String, dynamic>>.broadcast();
  final _adapterChanges = StreamController<AdapterReadiness>.broadcast();

  int? _watchId;

  @override
  String get description => 'browser geolocation (no host app)';

  /// No browser API exposes BLE advertisements; Web Bluetooth is a pairing
  /// API, not a scanning one.
  @override
  bool get providesBle => false;

  @override
  Future<AdapterReadiness> prepare({
    required bool ble,
    required bool gps,
  }) async {
    if (ble) {
      // Reported, not thrown: the caller decides whether a GPS-only fix is
      // good enough for the mode it is running.
      debugPrint(
        'No host app bridge: BLE scanning is unavailable in a browser, '
        'positioning will use GPS alone.',
      );
    }
    return const AdapterReadiness.ready();
  }

  @override
  Future<void> startBle(ScanSessionConfig config) async {
    throw const ScanSourceUnsupported(
      'A browser cannot scan for BLE beacons. Open this venue in the app.',
    );
  }

  @override
  Future<void> stopBle() async {}

  @override
  Future<void> startGps(ScanSessionConfig config) async {
    await stopGps();

    _watchId = web.window.navigator.geolocation.watchPosition(
      ((web.GeolocationPosition position) {
        final coords = position.coords;
        _gpsFixes.add(<String, dynamic>{
          'latitude': coords.latitude,
          'longitude': coords.longitude,
          'accuracy': coords.accuracy,
          'bearing': coords.heading ?? -1,
          'altitude': coords.altitude ?? 0,
          'speed': coords.speed ?? -1,
          'timestamp': position.timestamp,
        });
      }).toJS,
      ((web.GeolocationPositionError error) {
        debugPrint('Browser geolocation error ${error.code}: ${error.message}');
        _adapterChanges.add(
          AdapterReadiness.unavailable('Geolocation: ${error.message}'),
        );
      }).toJS,
      web.PositionOptions(
        enableHighAccuracy: true,
        maximumAge: config.gpsInterval.inMilliseconds,
      ),
    );
  }

  @override
  Future<void> stopGps() async {
    final id = _watchId;
    if (id != null) {
      web.window.navigator.geolocation.clearWatch(id);
      _watchId = null;
    }
  }

  @override
  Stream<List<Map<String, dynamic>>> get bleBatches =>
      const Stream<List<Map<String, dynamic>>>.empty();

  @override
  Stream<Map<String, dynamic>> get gpsFixes => _gpsFixes.stream;

  /// `DeviceOrientationEvent` needs a user-gesture permission prompt that is
  /// unreliable inside an embedded WebView, and this source only ever runs
  /// where there is no compass worth trusting anyway.
  @override
  Stream<double> get headings => const Stream<double>.empty();

  @override
  Stream<AdapterReadiness> get adapterChanges => _adapterChanges.stream;

  @override
  Future<void> dispose() async {
    await stopGps();
    await _gpsFixes.close();
    await _adapterChanges.close();
  }
}
