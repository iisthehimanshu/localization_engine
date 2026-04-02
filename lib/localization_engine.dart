import 'dart:async';

import 'package:adapter_manager/adapter_manager.dart';
import 'package:device_meta/device_meta.dart';
import 'package:flutter/services.dart';
import 'package:localization_engine/src/GPS/GPSBuffer.dart';
import 'package:localization_engine/src/config/config.dart';
import 'package:localization_engine/src/network/api/UserTrackingWebSocket.dart';

import 'initialLocalization.dart';
import 'location.dart';
import 'nearest_beacon_resolver.dart';

export 'package:adapter_manager/adapter_manager.dart';

class LocalizationEngine{
  final MethodChannel _methodChannel = MethodChannel('localization_engine');
  final EventChannel _bleEventChannel = EventChannel('ble_scan_stream');
  final EventChannel _gpsEventChannel = EventChannel('gps_scan_stream');

  InitialLocalization? _localization;
  final _gpsBuffer = GPSBuffer();

  bool _isScanning = false;
  bool get isScanning => _isScanning;

  static final wsService = WebSocketService();

  final _userLocation = StreamController<LocalizationEngineLocation>.broadcast();
  Stream<Map<String, dynamic>> get userLocation => _userLocation.stream.map((location) => location.toJson());

  LocalizationEngine(String venueName, {String? baseURL}){
    AppConfig.url = baseURL;
    init(venueName: venueName);
  }

  Future<void> init({required String venueName}) async {
    await _startScanning(venueName: venueName);
    _getCurrentLocation(venueName: venueName);
    _trackUserLocation(venueName: venueName);
  }

  Future<Map<String, dynamic>> _checkAllStatus() async {
    final result = await AdapterManager.setupAllPermissionsAndAdapters();
    return result;
  }

  Future<void> _setVenue({required String venueName})async{
    _localization = InitialLocalization(venueName);
    _localization?.parseBeaconMap(venueName);
  }

  Future<void> _startScanning({
    required String venueName
  }) async {
    if (_isScanning) {
      throw StateError('Scanning is already in progress');
    }
    var adapterState = await _checkAllStatus();
    print("adapterState $adapterState");
    if(adapterState['success']){
      await _setVenue(venueName: venueName);
      await _methodChannel.invokeMethod('startGpsScan');
      await _methodChannel.invokeMethod('startScan');
      _isScanning = true;
    }else if(adapterState['PermanentlyDenied']){
      throw PermissionException(adapterState['errors'].first);
    }else{
      throw AdapterException(adapterState['errors'].first);
    }
  }

  Future<void> _stopScanning() async {
    await _methodChannel.invokeMethod('stopScan');
    await _methodChannel.invokeMethod('stopGpsScan');
    _isScanning = false;
  }

  Stream<Map<String, dynamic>?> get bluetoothScanResults =>
      _bleEventChannel.receiveBroadcastStream().asyncMap((event) async {
        try {
          final List<dynamic> rawList = event as List;
          for(var entry in rawList){
            final map = Map<String, dynamic>.from(entry);
            return map;
          }
        } catch (e) {
          print('Error processing rawBluetoothScanResults scan result: $e');
          return null; // or rethrow based on your needs
        }
      }).handleError((error) {
        print('Stream error: $error');
      }).asBroadcastStream();

  Stream<Map<String, dynamic>?> get gpsScanResults =>
      _gpsEventChannel.receiveBroadcastStream().asyncMap((event) async {
        return Map<String, dynamic>.from(event as Map);
      }).handleError((error) {
        print('gpsStreamRaw error: $error');
      });

  Future<void> _getCurrentLocation({
    required String venueName,
  }) async {
    BeaconPointLocation? beaconLocation;
    GPSLocation? gpsLocation;

    // Buffers shared across iterations
    final List<Map<String, dynamic>> bleData = [];
    final List<Map<String, dynamic>> gpsData = [];

    // Attach listeners ONCE
    final bleSubscription = bluetoothScanResults.listen((data) {
      if (data != null) bleData.add(data);
    });

    final gpsSubscription = gpsScanResults.listen((data) {
      if (data != null) gpsData.add(data);
    });

    Future<void> collectAndEmit() async {
      // Wait for data to accumulate
      await Future.delayed(const Duration(seconds: 6));

      // Snapshot and clear buffers atomically for this window
      final bleBatch = List<Map<String, dynamic>>.from(bleData);
      final gpsBatch = List<Map<String, dynamic>>.from(gpsData);
      bleData.clear();
      gpsData.clear();

      try {
        final scanData = groupByDevice(bleBatch);
        final filteredData = _localization?.filterBeacons(scanData) ?? scanData;

        final resolver = NearestBeaconResolver(_localization!);
        beaconLocation = resolver.resolve(filteredData);

        for (var data in gpsBatch) {
          _gpsBuffer.add(data['latitude'], data['longitude']);
        }
        List<double>? gpsBufferLocation = _gpsBuffer.getRobustPosition();
        if (gpsBufferLocation != null) {
          gpsLocation = GPSLocation(
            latitude: gpsBufferLocation[0],
            longitude: gpsBufferLocation[1],
          );
        }

        _userLocation.add(LocalizationEngineLocation(
          beaconLocation: beaconLocation,
          gpsLocation: gpsLocation,
        ));

      } on StateError {
        List<double>? gpsBufferLocation = _gpsBuffer.getRobustPosition();
        if (gpsBufferLocation != null) {
          gpsLocation = GPSLocation(
            latitude: gpsBufferLocation[0],
            longitude: gpsBufferLocation[1],
          );
        }
        _userLocation.add(LocalizationEngineLocation(
          beaconLocation: beaconLocation,
          gpsLocation: gpsLocation,
        ));

      } on AdapterException {
        bleSubscription.cancel();
        gpsSubscription.cancel();
        rethrow;
      } on PermissionException {
        bleSubscription.cancel();
        gpsSubscription.cancel();
        rethrow;
      } catch (_) {}
    }

    try {
      while (true) {
        await collectAndEmit();
      }
    } finally {
      // Guaranteed cleanup if the loop ever exits
      bleSubscription.cancel();
      gpsSubscription.cancel();
    }
  }

  Map<String, List<MapEntry<DateTime, int>>> groupByDevice(
      List<Map<String, dynamic>> data,
      ) {
    final Map<String, List<MapEntry<DateTime, int>>> result = {};

    for (final item in data) {
      try {
        final String name = item['name'];

        // Handle both String and DateTime safely
        final DateTime timestamp = item['timestamp'] is DateTime
            ? item['timestamp']
            : DateTime.parse(item['timestamp'].toString());

        final int rssi = item['rssi'] is int
            ? item['rssi']
            : int.parse(item['rssi'].toString());

        result.putIfAbsent(name, () => []);
        result[name]!.add(MapEntry(timestamp, rssi));
      } catch (e) {
        // Optional: skip bad entries
        print('Error parsing item: $e');
      }
    }

    return result;
  }

  Future<void> _trackUserLocation({
    required String venueName,
  }) async {
    final deviceMeta = await DeviceMeta.init(storageKey: "localizationEngine");
    wsService.connect();

    _userLocation.stream.listen((data){
      BeaconPointLocation? beaconLocation = data.beaconLocation;
      GPSLocation? gpsLocation = data.gpsLocation;

      if(gpsLocation == null && beaconLocation == null) return;

      final payload = TrackingPayload(
        id: deviceMeta.uuid!,
        t: DateTime.now().millisecondsSinceEpoch,
        pts: {
          if(beaconLocation != null)
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
              beaconLocation?.floor,
              2,
            ],
        },
        venueName: venueName,
      );

      wsService.sendTracking(payload);
    });
  }

}