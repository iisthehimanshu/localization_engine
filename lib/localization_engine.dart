import'dart:async';
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
import 'package:localization_engine/src/localizationAlgorithm/ble_position_estimator.dart';
import 'package:localization_engine/src/network/api/UserTrackingWebSocket.dart';
import 'package:localization_engine/src/network/api/beaconapi.dart';
import 'package:localization_engine/src/network/model/beaconData.dart';

import 'initialLocalization.dart';
import 'location.dart';
import 'nearest_beacon_resolver.dart';

export 'package:adapter_manager/adapter_manager.dart';

/// The venue beacon model (name, building, floor and lat/long) is re-exported
/// so consumers can render or diagnose the configured beacons directly.
export 'src/network/model/beaconData.dart';

/// Real-time indoor + outdoor positioning engine.
///
/// Fuses BLE beacon scanning with GPS to estimate a user's location inside a
/// configured venue, exposes the result via the [userLocation] stream, and
/// reports the position to the backend over a WebSocket for live tracking.
///
/// Constructing an instance immediately begins permission setup, scanning,
/// location resolution, and tracking — there is no separate start call.
///
/// ```dart
/// final engine = LocalizationEngine('IITDelhi');
/// engine.userLocation.listen((location) {
///   // handle fused beacon/GPS location
/// });
/// ```
class LocalizationEngine{
  final MethodChannel _methodChannel = MethodChannel('localization_engine');
  final EventChannel _bleEventChannel = EventChannel('ble_scan_stream');
  final EventChannel _gpsEventChannel = EventChannel('gps_scan_stream');

  InitialLocalization? _localization;
  final _gpsBuffer = GPSBuffer();

  bool _isScanning = false;

  /// Whether the engine is currently scanning for beacons and GPS samples.
  bool get isScanning => _isScanning;

  /// Shared WebSocket service used to stream tracking payloads to the backend.
  static final wsService = WebSocketService();

  final _userLocation = StreamController<LocalizationEngineLocation>.broadcast();

  /// Primary output stream of fused location updates.
  ///
  /// Emits roughly every 1 second (the tick interval), each decision based on
  /// up to the last 6 seconds of data. Each event is the
  /// JSON form of a [LocalizationEngineLocation] — a map with `beaconLocation`,
  /// `gpsLocation`, and `message` keys, any of which may be `null`.
  Stream<Map<String, dynamic>> get userLocation => _userLocation.stream.map((location) => location.toJson());
  StreamSubscription<LocalizationEngineLocation>? _trackingSubscription;
  Future<void>? _locationLoopTask;
  int _runId = 0;
  final detector = PeakValleyDetector(historySize: 4);

  /// When `true`, indoor positions are resolved with [BLEPositionEstimator]
  /// (softmax-weighted centroid + EMA smoothing). When `false`, the engine
  /// falls back to the original [NearestBeaconResolver]. Flip this to switch
  /// algorithms.
  bool useBLEPositionEstimator = true;

  /// Persistent estimator instance so its rolling window / EMA state survives
  /// across collection windows. Lazily created once the beacon map is loaded.
  BLEPositionEstimator? _positionEstimator;

  /// Per-building, per-floor tuning thresholds, keyed as
  /// `buildingId -> floor -> settingName -> value`.
  ///
  /// Recognized settings are `initialLocalizationThreshold` (minimum `|RSSI|`
  /// to accept a beacon fix, default `85`) and `peakValley` (minimum peak RSSI
  /// for a peak/valley hit, default `-75`).
  static Map<String, Map<int, Map<String, dynamic>>>? floorConfig;

  /// Creates the engine for [venueName] and immediately starts scanning,
  /// location resolution, and backend tracking.
  ///
  /// [baseURL] overrides the backend base URL (defaults to the dev/prod URL
  /// based on build mode). [floorConfig] supplies optional per-floor tuning
  /// thresholds; see [LocalizationEngine.floorConfig].
  LocalizationEngine(String venueName, {String? baseURL, Map<String, Map<int, Map<String, dynamic>>>? floorConfig}){
    LocalizationEngine.floorConfig = floorConfig;
    AppConfig.url = baseURL;
    init(venueName: venueName);
  }

  /// Starts (or re-starts) scanning, the resolution loop, and tracking for
  /// [venueName].
  ///
  /// Called automatically by the constructor — you normally don't invoke this
  /// directly. Use [restart] to cleanly re-initialize an existing instance.
  Future<void> init({required String venueName}) async {
    print("init called of localization");
    _runId++;
    await _startScanning(venueName: venueName);
    _locationLoopTask = _getCurrentLocation(venueName: venueName, runId: _runId);
    _trackUserLocation(venueName: venueName);
  }

  static void setFloorConfig(Map<String, Map<int, Map<String, dynamic>>>? updatedFloorConfig){
    print("updatedFloorConfig ${updatedFloorConfig}");
    floorConfig = updatedFloorConfig;
  }

  /// Cleanly tears down the current run and re-initializes for [venueName].
  ///
  /// Cancels in-flight loops and subscriptions, resets internal state, clears
  /// the GPS buffer, and reconnects the WebSocket. Call this after the user
  /// grants previously denied permissions or to switch venues.
  Future<void> restart({required String venueName}) async {
    // Invalidate in-flight loops/listeners and stop active scanning first.
    _runId++;
    await _stopScanning();
    await _trackingSubscription?.cancel();
    _trackingSubscription = null;

    // Reset internal state
    _localization = null;
    _positionEstimator = null;
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
      initEstimatorLocationStream();
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
    await _stopEstimatorLocationStream();
    await _bleSubscription?.cancel();
    _bleSubscription = null;
    await _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _isScanning = false;
  }

  final _bleController = StreamController<Map<String, dynamic>?>.broadcast();

  /// Raw, RSSI-filtered BLE scan results (`|rssi|` kept within `55`–`110`).
  ///
  /// Intended for diagnostics, logging, or signal-strength UIs. For resolved
  /// positions use [userLocation] instead.
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

          final rawRssi = map['rssi'];
          if (rawRssi == null) continue;
          final rssi = (rawRssi as num).abs();
          if (rssi < 50 || rssi > 110) continue;

          // Native now delivers a batch per event rather than one reading, so
          // this must forward every accepted entry — returning here would drop
          // all but the first reading of each flush.
          _bleController.add(map);
        }
      } catch (e) {
        print('Error processing rawBluetoothScanResults scan result: $e');
        return; // or rethrow based on your needs
      }
    }, onError: (error) {
      print('bleStream error: $error');
    });
  }

  final _estimatorLocationController =
      StreamController<BeaconPointLocation?>.broadcast();

  /// Estimator-resolved location updates, emitted once per second.
  ///
  /// Driven solely by [bluetoothScanResults]: every second the readings that
  /// arrived during the previous second are grouped, filtered, and passed to
  /// [_resolveWithEstimator]. Each tick emits the resulting
  /// [BeaconPointLocation] (or `null` when no fix could be resolved).
  Stream<BeaconPointLocation?> get estimatorLocationStream =>
      _estimatorLocationController.stream;

  StreamSubscription<Map<String, dynamic>?>? _estimatorBleSubscription;
  Timer? _estimatorTimer;

  /// Dedicated estimator for [estimatorLocationStream] so its rolling-window /
  /// EMA state stays independent of the main loop's [_positionEstimator].
  BLEPositionEstimator? _estimatorStreamEstimator;

  /// Starts the per-second estimator loop over [bluetoothScanResults].
  ///
  /// Buffers incoming BLE scan results and, every second, hands the previous
  /// second's batch to [_resolveWithEstimator], pushing the result onto
  /// [estimatorLocationStream].
  void initEstimatorLocationStream() {
    if (_estimatorBleSubscription != null || _estimatorTimer != null) return;

    // Own estimator instance — independent state from the main loop.
    final localization = _localization;
    _estimatorStreamEstimator ??= localization == null
        ? null
        : BLEPositionEstimator(beaconDb: localization.apibeaconmap);

    // Buffer of readings received during the current 1-second interval.
    final List<Map<String, dynamic>> buffer = [];

    _estimatorBleSubscription = bluetoothScanResults.listen((data) {
      if (data != null) buffer.add(data);
    });

    _estimatorTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Snapshot and clear the previous second's readings atomically.
      final batch = List<Map<String, dynamic>>.from(buffer);
      buffer.clear();

      final scanData = groupByDevice(batch);
      final filteredData = _localization?.filterBeacons(scanData) ?? scanData;
      _estimatorLocationController.add(_resolveWithEstimator(filteredData,
          estimator: _estimatorStreamEstimator));
    });
  }

  Future<void> _stopEstimatorLocationStream() async {
    _estimatorTimer?.cancel();
    _estimatorTimer = null;
    await _estimatorBleSubscription?.cancel();
    _estimatorBleSubscription = null;
    _estimatorStreamEstimator = null;
  }

  final _gpsController = StreamController<Map<String, dynamic>?>.broadcast();

  /// Raw GPS samples emitted by the native side (`latitude`/`longitude`).
  ///
  /// Intended for diagnostics. For resolved positions use [userLocation].
  Stream<Map<String, dynamic>?> get gpsScanResults => _gpsController.stream;

  StreamSubscription? _gpsSubscription;

  void initGpsStream() {
    _gpsSubscription ??= _gpsEventChannel
        .receiveBroadcastStream()
        .listen((event) {
      try {
        final map = Map<String, dynamic>.from(event as Map);
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

    // Sliding window / tick length. Every [tickSeconds] we emit a decision
    // based on (up to) the last [windowSeconds] of data.
    const windowSeconds = 6;
    const tickSeconds = 1;

    // Raw incoming buffers, drained into the 1-second increment each tick.
    final List<Map<String, dynamic>> bleData = [];
    final List<Map<String, dynamic>> gpsData = [];

    // 6-second sliding BLE window, used only by the fallback resolver.
    // (The estimator keeps its own internal rolling window; GPS windowing
    // lives in GPSBuffer.)
    final List<MapEntry<DateTime, Map<String, dynamic>>> bleWindow = [];

    // Attach listeners ONCE
    final bleSubscription = bluetoothScanResults.listen((data) {
      if (data != null) bleData.add(data);
    });

    final gpsSubscription = gpsScanResults.listen((data) {
      if (data != null) gpsData.add(data);
    });

    Future<void> collectAndEmit() async {
      BeaconPointLocation? beaconLocation;
      GPSLocation? gpsLocation;
      // Wait one tick for fresh data to arrive.
      await Future.delayed(const Duration(seconds: tickSeconds));

      // Snapshot and clear the 1-second increment atomically for this tick.
      final now = DateTime.now();
      final bleIncrement = List<Map<String, dynamic>>.from(bleData);
      final gpsIncrement = List<Map<String, dynamic>>.from(gpsData);
      bleData.clear();
      gpsData.clear();

      try {
        if (useBLEPositionEstimator) {
          // Estimator keeps its own 6s rolling window — feed only the new
          // readings each tick.
          final scanData = groupByDevice(bleIncrement);
          final filteredData =
              _localization?.filterBeacons(scanData) ?? scanData;
          beaconLocation = _resolveWithEstimator(filteredData);
        } else {
          // Stateless resolver — feed it the whole 6s sliding BLE window.
          for (final item in bleIncrement) {
            bleWindow.add(MapEntry(now, item));
          }
          final cutoff = now.subtract(const Duration(seconds: windowSeconds));
          bleWindow.removeWhere((e) => e.key.isBefore(cutoff));

          final windowBatch = bleWindow.map((e) => e.value).toList();
          final scanData = groupByDevice(windowBatch);
          final filteredData =
              _localization?.filterBeacons(scanData) ?? scanData;
          final resolver = NearestBeaconResolver(_localization!);
          beaconLocation = resolver.resolve(filteredData);
        }
        int? bestFloor = beaconLocation?.bestFloor;
        // if (beaconLocation != null && beaconLocation.rssi != null) {
        //   final threshold = floorConfig?[beaconLocation.bid]?[beaconLocation.floor]?["initialLocalizationThreshold"] ?? 75;
        //   print("initialLocalizationThreshold ${floorConfig?[beaconLocation.bid]?[beaconLocation.floor]?["initialLocalizationThreshold"]?.abs()}");
        //   if (threshold.abs() < beaconLocation.rssi!.abs()) {
        //     beaconLocation = null;
        //   }
        // }

        // for (var event in bleBatch) {
        //   var result = detector.processEvent(event);
        //   // print("peakValley Result found $result");
        //   if(result != null){
        //     var beacon = _localization?.getBeaconDetails(result.name);
        //     if(beacon != null && (floorConfig?[beacon.buildingID]?[beacon.floor]?["peakValley"]??70).abs() > result.peakRssi.abs()){
        //       print("peakValleyBeacon ${beacon.name} ${result.peakRssi.abs()}    floorConfig Threshold ${(floorConfig?[beacon.buildingID]?[beacon.floor]?["peakValley"])?.abs()}");
        //       beaconLocation = BeaconPointLocation(x: beacon.coordinateX!, y: beacon.coordinateY!, bid: beacon.buildingID!, floor: beacon.floor!, latitude: double.parse(beacon.properties!.latitude!), longitude: double.parse(beacon.properties!.longitude!), beacons: [result.name], rssi: result.peakRssi.toDouble(), bestFloor: beacon.floor!);
        //     }else{
        //       print("PeakValley result discarded for ${result.name}");
        //     }
        //   }
        // }

        for (var data in gpsIncrement) {
          _gpsBuffer.add(data['latitude'], data['longitude']);
        }
        List<double>? gpsBufferLocation = _gpsBuffer
            .getWindowedRobustPosition(const Duration(seconds: windowSeconds));
        if (gpsBufferLocation != null && (bestFloor == null || bestFloor == 0)) {
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
        List<double>? gpsBufferLocation = _gpsBuffer
            .getWindowedRobustPosition(const Duration(seconds: windowSeconds));
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

  /// Resolves an indoor position with [BLEPositionEstimator], mapping its
  /// [PositionResult] onto a [BeaconPointLocation].
  ///
  /// The smoothed coordinates become [BeaconPointLocation.x]/[y]; every other
  /// field (building, floor, lat/lon) is read from the rank-1 beacon looked up
  /// in [InitialLocalization.apibeaconmap]. Returns `null` when the estimator
  /// has no fix or the rank-1 beacon is not in the map.
  ///
  /// Pass [estimator] to resolve against a specific [BLEPositionEstimator]
  /// instance (e.g. the estimator-stream's own estimator); when omitted the
  /// shared [_positionEstimator] used by the main loop is lazily created and
  /// used.
  BeaconPointLocation? _resolveWithEstimator(
      Map<String, List<MapEntry<DateTime, int>>> filteredData,
      {BLEPositionEstimator? estimator}) {
    final localization = _localization;
    if (localization == null) return null;

    // Lazily build the estimator over the loaded beacon map.
    final activeEstimator = estimator ??
        (_positionEstimator ??=
            BLEPositionEstimator(beaconDb: localization.apibeaconmap));

    // Flatten grouped scan data into individual timestamped readings.
    final readings = <BleReading>[];
    filteredData.forEach((name, entries) {
      for (final e in entries) {
        readings.add(BleReading(name: name, rssi: e.value, timestamp: e.key));
      }
    });

    final pos = activeEstimator.update(readings, walking: true);
    if (pos == null) return null;

    final rank1 = localization.apibeaconmap[pos.rank1Beacon];
    if (rank1 == null) return null;

    // Building/floor come from the estimator, not the rank-1 beacon: they are
    // what the coordinates were actually resolved against.
    return BeaconPointLocation(
      x: pos.smoothX.round(),
      y: pos.smoothY.round(),
      bid: pos.building,
      floor: pos.floor,
      latitude: double.parse(rank1.properties!.latitude!),
      longitude: double.parse(rank1.properties!.longitude!),
      beacons: [pos.rank1Beacon],
      rssi: pos.rank1Rssi.toDouble(),
      bestFloor: pos.floor,
    );
  }

  Map<String, List<MapEntry<DateTime, int>>> groupByDevice(
      List<Map<String, dynamic>> data,
      ) {
    final Map<String, List<MapEntry<DateTime, int>>> result = {};

    for (final item in data) {
      try {
        final String name = item['name'];

        // Handle DateTime, epoch millis (what native sends), and String.
        final rawTimestamp = item['timestamp'];
        final DateTime timestamp = rawTimestamp is DateTime
            ? rawTimestamp
            : rawTimestamp is int
                ? DateTime.fromMillisecondsSinceEpoch(rawTimestamp)
                : DateTime.parse(rawTimestamp.toString());

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

  /// Fetches the venue's configured beacons (cache-first) for rendering or
  /// diagnostics.
  ///
  /// Each [Beacon] carries its `name` (matching the `name` seen on
  /// [bluetoothScanResults]), `buildingID`, `floor`, and geographic position
  /// via `properties.latitude` / `properties.longitude`. Useful for plotting
  /// the full beacon layout on a map and cross-referencing which of them are
  /// currently visible on the BLE scan stream.
  Future<List<Beacon>> fetchVenueBeacons(String venueName) =>
      beaconapi().fetchBeaconData(venueName);

}