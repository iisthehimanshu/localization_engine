import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:adapter_manager/adapter_manager.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localization_engine/src/GPS/GPSBuffer.dart';
import 'package:localization_engine/src/PeakValleyDetector.dart';
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
  StreamSubscription<LocalizationEngineLocation>? _trackingSubscription;
  Future<void>? _locationLoopTask;
  int _runId = 0;
  final detector = PeakValleyDetector(historySize: 4);

  LocalizationEngine(String venueName, {String? baseURL}){
    AppConfig.url = baseURL;
    init(venueName: venueName);
  }

  Future<void> init({required String venueName}) async {
    print("init called of localization");
    _runId++;
    await _startScanning(venueName: venueName);
    _locationLoopTask = _getCurrentLocation(venueName: venueName, runId: _runId);
    _trackUserLocation(venueName: venueName);
  }

  Future<void> restart({required String venueName}) async {
    // Invalidate in-flight loops/listeners and stop active scanning first.
    _runId++;
    await _stopScanning();
    await _trackingSubscription?.cancel();
    _trackingSubscription = null;

    // Reset internal state
    _localization = null;
    _gpsBuffer.clear();

    // Reconnect WebSocket
    wsService.connect();

    // Reinitialize
    await init(venueName: venueName);
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
      await _stopScanning();
    }
    var adapterState = await _checkAllStatus();
    print("adapterState $adapterState");
    if(adapterState['success']){
      await _setVenue(venueName: venueName);
      await _methodChannel.invokeMethod('startGpsScan');
      await _methodChannel.invokeMethod('startScan');
      initGpsStream();
      initBleStream();
      _isScanning = true;
    }else if(adapterState['PermanentlyDenied'] || adapterState['errors'].first.contains("permission denied")){
      throw PermissionException(adapterState['errors'].first);
    }else{
      throw AdapterException(adapterState['errors'].first);
    }
  }

  Future<void> _stopScanning() async {
    await _methodChannel.invokeMethod('stopScan');
    await _methodChannel.invokeMethod('stopGpsScan');
    await _bleSubscription?.cancel();
    _bleSubscription = null;
    await _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _isScanning = false;
  }

  final _bleController = StreamController<Map<String, dynamic>?>.broadcast();

  Stream<Map<String, dynamic>?> get bluetoothScanResults => _bleController.stream;

  StreamSubscription? _bleSubscription;

  void initBleStream() {
    _bleSubscription ??= _bleEventChannel
        .receiveBroadcastStream()
        .listen((event) {
      try {
        final List<dynamic> rawList = event as List;
        for(var entry in rawList){
          final map = Map<String, dynamic>.from(entry);
          _bleController.add(map);
          return;
        }
      } catch (e) {
        print('Error processing rawBluetoothScanResults scan result: $e');
        return; // or rethrow based on your needs
      }
    }, onError: (error) {
      print('bleStream error: $error');
    });
  }

  final _gpsController = StreamController<Map<String, dynamic>?>.broadcast();

  Stream<Map<String, dynamic>?> get gpsScanResults => _gpsController.stream;

  StreamSubscription? _gpsSubscription;

  void initGpsStream() {
    _gpsSubscription ??= _gpsEventChannel
        .receiveBroadcastStream()
        .listen((event) {
      try {
        final map = Map<String, dynamic>.from(event as Map);
        print("_gpsController $map");
        _gpsController.add(map);
      } catch (e) {
        print('gpsStreamRaw error: $e');
        _gpsController.add(null);
      }
    }, onError: (error) {
      print('gpsStreamRaw error: $error');
    });
  }

  Future<void> _getCurrentLocation({
    required String venueName,
    required int runId,
  }) async {

    // Buffers shared across iterations
    final List<Map<String, dynamic>> bleData = [];
    final List<Map<String, dynamic>> gpsData = [];

    // Attach listeners ONCE
    final bleSubscription = bluetoothScanResults.listen((data) {
      if (data != null) bleData.add(data);
    });

    final gpsSubscription = gpsScanResults.listen((data) {
      print("gpsSubscriptionDebuggggg  data incoming ${data}");
      if (data != null) gpsData.add(data);
    });

    Future<void> collectAndEmit() async {
      BeaconPointLocation? beaconLocation;
      GPSLocation? gpsLocation;
      // Wait for data to accumulate
      await Future.delayed(const Duration(seconds: 3));

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
        for (var event in bleBatch) {
          var result = detector.processEvent(event);
          print("peakValley Result found $result");
          if(result != null){
            var beacon = _localization?.getBeaconDetails(result.name);
            if(beacon != null){
              print("peakValleyBeacon ${beacon.name}");
              beaconLocation = BeaconPointLocation(x: beacon.coordinateX!, y: beacon.coordinateY!, bid: beacon.buildingID!, floor: beacon.floor!, latitude: double.parse(beacon.properties!.latitude!), longitude: double.parse(beacon.properties!.longitude!), beacons: [result.name]);
            }else{
              print("PeakValley result discarded for ${result.name}");
            }
          }
        }

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

        print("adding userLocation in collect&emit");

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
        // gpsSubscription.cancel();
        rethrow;
      } on PermissionException {
        bleSubscription.cancel();
        gpsSubscription.cancel();
        rethrow;
      } catch (e) {
        print("error in collect and emmit $e");
      }
    }

      while (_isScanning && runId == _runId) {
      try{
        await collectAndEmit();
      }catch(e){
        print("error in getCurrent Location gpsSubscriptionDebuggggg ${e}");
      }

      }

      await bleSubscription.cancel();
      await gpsSubscription.cancel();
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

  Future<String> _getDeviceId() async {
    try {
      final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
      String? id;
      if (kIsWeb) {
        final webInfo = await deviceInfo.webBrowserInfo;
        id = 'web_${webInfo.userAgent.hashCode}';
      } else if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        id = androidInfo.id;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        id = iosInfo.identifierForVendor;
      } else if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        id = macInfo.systemGUID;
      } else if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        id = windowsInfo.deviceId;
      } else if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        id = linuxInfo.machineId;
      }
      if(id == null){
        return _generateFallbackId();
      }else{
        return id;
      }
    } catch (e) {
      print("❌ Error getting device ID: $e");
      return _generateFallbackId();
    }
  }

  String _generateFallbackId() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return base64UrlEncode(values).substring(0, 22);
  }

  Future<void> _trackUserLocation({
    required String venueName,
  }) async {
    print("_trackUserLocation");
    final deviceId = await _getDeviceId();
    print("_trackUserLocation $deviceId");
    wsService.connect();

    await _trackingSubscription?.cancel();
    _trackingSubscription = _userLocation.stream.listen((data){
      print("recieved data in _trackUserLocation");
      BeaconPointLocation? beaconLocation = data.beaconLocation;
      GPSLocation? gpsLocation = data.gpsLocation;
      if(gpsLocation == null && beaconLocation == null) return;

      final payload = TrackingPayload(
        id: deviceId,
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