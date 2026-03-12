import 'dart:async';

import 'package:adapter_manager/adapter_manager.dart';
import 'package:device_meta/device_meta.dart';
import 'package:localization_engine/location.dart';
import 'package:localization_engine/src/network/api/UserTrackingWebSocket.dart';
import 'package:localization_engine/src/network/api/localizationUsingMLModelapi.dart';

import 'LocalizationException.dart';
import 'Point.dart';
import 'initialLocalization.dart';
import 'ble_scanner.dart';
import 'gps_scanner.dart';
import 'nearest_beacon_resolver.dart';

export 'Point.dart';
export 'LocalizationException.dart';
export 'package:adapter_manager/adapter_manager.dart';
export 'package:adapter_manager/AdapterException.dart';
export 'package:adapter_manager/UI/LocationServicesDialog.dart';

class LocalizationEngine {
  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  static InitialLocalization? _localization;
  static BleScanner? _ble;
  static final _gps = GpsScanner();
  static bool _isScanning = false;
  static final wsService = WebSocketService();
  static bool get isScanning => _isScanning;

  // ---------------------------------------------------------------------------
  // Public API – lifecycle
  // ---------------------------------------------------------------------------

  static Future<void> startScanning({
    Duration? frequency,
    Duration? bufferSize,
    Duration? timeout,
    bool immediateEmit = false,
    required String venueName,
  }) async {
    if (_isScanning) throw StateError('Scanning is already in progress');

    final adapterState = await AdapterManager.setupAllPermissionsAndAdapters();

    if (!adapterState['success']) {
      final error = adapterState['errors'].first as String;
      if (adapterState['PermanentlyDenied'] == true) {
        throw PermissionException(error);
      }
      throw AdapterException(error);
    }

    _localization = InitialLocalization(venueName)
      ..parseBeaconMap(venueName);

    _ble = BleScanner(
      frequency: frequency,
      bufferSize: bufferSize,
      timeout: timeout,
      immediateEmit: immediateEmit,
    );

    wsService.connect();

    await _ble!.initialize();
    await _gps.start();
    await _ble!.start();

    _isScanning = true;
  }

  static Future<void> stopScanning() async {
    await _ble?.stop();
    await _gps.stop();
    wsService.disconnect();
    _isScanning = false;
  }

  static Future<void> dispose() async {
    await stopScanning();
    _localization = null;
  }

  // ---------------------------------------------------------------------------
  // Public API – streams
  // ---------------------------------------------------------------------------

  /// Emits the estimated [Pt] position on each BLE scan cycle.
  static Stream<Pt?> get scanResults =>
      _requireBle().beaconStream.asyncMap((data) async {
        try {
          return await _localization?.findLocation(data.readings);
        } catch (e) {
          print('Error processing scan result: $e');
          return null;
        }
      }).handleError((Object e) => print('scanResults stream error: $e'));

  /// Emits the raw beacon RSSI map on each BLE scan cycle.
  static Stream<Map<String, List<MapEntry<DateTime, int>>>?> get scanResultsForAllBeacons =>
      _requireBle().beaconStream.asyncMap((data) async {
        try {
          return data.readings;
        } catch (e) {
          print('Error processing scan result: $e');
          return null;
        }
      });

  /// Emits raw GPS data maps.
  static Stream<Map<String, dynamic>> get gpsStreamRaw => _gps.rawStream;

  // ---------------------------------------------------------------------------
  // Public API – one-shot location
  // ---------------------------------------------------------------------------

  /// Starts scanning, waits for the first usable BLE event, then stops.
  ///
  /// Returns a JSON map with `beaconLocation` and `gpsLocation` fields,
  /// or null on unexpected errors.
  static Future<Map<String, dynamic>?> getCurrentLocation({
    required String venueName,
  }) async {
    try {
      await startScanning(
        frequency: const Duration(seconds: 5),
        bufferSize: const Duration(seconds: 6),
        timeout: const Duration(seconds: 7),
        venueName: venueName,
      );

      await _gps.start(); // ensure GPS is buffering while we wait for BLE

      final scanData = await _waitForFirstBeaconData();
      final filteredData = _localization?.filterBeacons(scanData) ?? scanData;

      final resolver = NearestBeaconResolver(_localization!);
      final beaconLocation = resolver.resolve(filteredData);
      final gpsLocation = _gps.currentLocation;

      return LocalizationEngineLocation(
        beaconLocation: beaconLocation,
        gpsLocation: gpsLocation,
      ).toJson();
    } on StateError {
      // Already scanning – return whatever GPS data we have.
      return LocalizationEngineLocation(
        beaconLocation: null,
        gpsLocation: _gps.currentLocation,
      ).toJson();
    } on AdapterException {
      rethrow;
    } on PermissionException {
      rethrow;
    } catch (_) {
      return null;
    } finally {
      await stopScanning();
    }
  }

  static Timer? _trackingTimer;
  static StreamSubscription? _beaconSubscription;
  static Map<String, List<MapEntry<DateTime, int>>> _beaconBuffer = {};

  /// Start continuous location tracking — resolves & emits every 5 seconds.
  static Future<void> startTrackingUserLocation({
    required String venueName,
  }) async {
    final deviceMeta = await DeviceMeta.init(storageKey: "localizationEngine");

    await startScanning(
      immediateEmit: true,
      venueName: venueName,
    );

    // Buffer incoming beacon readings, merging into the window map
    _beaconBuffer.clear();
    _beaconSubscription?.cancel();
    _beaconSubscription = scanResultsForAllBeacons.listen((scanData) {
      if (scanData == null) return;
      scanData.forEach((key, entries) {
        _beaconBuffer.putIfAbsent(key, () => []).addAll(entries);
      });
    });

    _trackingTimer?.cancel();
    _trackingTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        // Snapshot and clear the buffer for this window
        final windowData = Map<String, List<MapEntry<DateTime, int>>>.from(_beaconBuffer);
        _beaconBuffer.clear();

        if (windowData.isEmpty) {
          print('[Tracking] ⚠️ No beacon data in this window, skipping emit.');
          return;
        }

        final filteredData = windowData;
        final resolver = NearestBeaconResolver(_localization!);
        final beaconLocation = resolver.resolve(filteredData);
        final gpsLocation = _gps.currentLocation;

        if (beaconLocation == null) {
          print('[Tracking] ⚠️ Could not resolve beacon location, skipping emit.');
          return;
        }

        final payload = TrackingPayload(
          id: deviceMeta.uuid!,
          t: DateTime.now().millisecondsSinceEpoch,
          pts: {
            'nb': [
              beaconLocation.x,
              beaconLocation.y,
              int.parse(beaconLocation.latitude.toString().replaceAll('.', '')),
              int.parse(beaconLocation.longitude.toString().replaceAll('.', '')),
              beaconLocation.floor,
              1,
            ],
            if (gpsLocation != null)
              'gp': [
                null,
                null,
                int.parse(gpsLocation.latitude.toString().replaceAll('.', '')),
                int.parse(gpsLocation.longitude.toString().replaceAll('.', '')),
                null,
                2,
              ],
          },
        );

        wsService.sendTracking(payload);
      } catch (e) {
        print('[Tracking] ❌ Error during periodic emit: $e');
      }
    });
  }

  /// Stop continuous tracking and clean up
  static Future<void> stopTrackingUserLocation() async {
    _trackingTimer?.cancel();
    _trackingTimer = null;
    await _beaconSubscription?.cancel();
    _beaconSubscription = null;
    _beaconBuffer.clear();
    await stopScanning();
    print('[Tracking] 🛑 Stopped tracking.');
  }

  // ---------------------------------------------------------------------------
  // Public API – ML model
  // ---------------------------------------------------------------------------

  static Future<dynamic> localizeUsingMLModelApiCall(
    Map<String, double> values,
  ) async {
    print('localizeUsingMLModel $values');
    return Localizationusingmlmodelapi().localize(values);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static BleScanner _requireBle() {
    assert(_ble != null, 'Call startScanning() before accessing BLE streams.');
    return _ble!;
  }

  /// Waits for the first non-empty BLE beacon data frame.
  static Future<Map<String, List<MapEntry<DateTime, int>>>> _waitForFirstBeaconData() async {
    final data = await _requireBle()
        .beaconStream
        .where((d) => !d.isEmpty)
        .first;
    return data.readings;
  }
}
