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
import 'package:localization_engine/src/localizationAlgorithm/ble_position_estimator.dart';
import 'package:localization_engine/src/localization_mode.dart';
import 'package:localization_engine/src/network/api/UserTrackingWebSocket.dart';
import 'package:localization_engine/src/network/api/beaconapi.dart';
import 'package:localization_engine/src/network/model/beaconData.dart';
import 'package:localization_engine/src/surrounding_device_rssi_aggregator.dart';

import 'initialLocalization.dart';
import 'location.dart';
import 'nearest_beacon_resolver.dart';

export 'package:adapter_manager/adapter_manager.dart';

/// The venue beacon model (name, building, floor and lat/long) is re-exported
/// so consumers can render or diagnose the configured beacons directly.
export 'src/network/model/beaconData.dart';
export 'src/localization_mode.dart';
export 'src/background/localization_background_service.dart';
export 'src/background/localization_service_configuration.dart';

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

class _AdapterSetupResult {
  const _AdapterSetupResult.success()
      : success = true,
        permissionDenied = false,
        error = null;

  const _AdapterSetupResult.failure(
    this.error, {
    this.permissionDenied = false,
  }) : success = false;

  final bool success;
  final bool permissionDenied;
  final String? error;
}

class LocalizationEngine {
  final MethodChannel _methodChannel = MethodChannel('localization_engine');
  final EventChannel _bleEventChannel = EventChannel('ble_scan_stream');
  final EventChannel _gpsEventChannel = EventChannel('gps_scan_stream');

  InitialLocalization? _localization;
  late String _venueName;
  final _gpsBuffer = GPSBuffer();

  bool _isScanning = false;
  bool _isDisposed = false;
  final bool _skipAdapterSetup;
  final LocalizationMode localizationMode;
  final DateTime? stopAt;
  final String? _baseURL;

  /// BLE observation window used for surrounding-device RSSI aggregation.
  ///
  /// One median RSSI per non-`IW` advertiser is attached under `devices` to
  /// the next `send-tracking` payload after each window. Platform identifiers
  /// may rotate and must not be treated as permanent device identities.
  final Duration surroundingDeviceScanInterval;

  bool get _usesGps => localizationMode != LocalizationMode.onlyBle;
  bool get _usesBle => localizationMode != LocalizationMode.onlyGps;

  /// Whether the engine is currently scanning for beacons and GPS samples.
  bool get isScanning => _isScanning;

  /// Shared WebSocket service used to stream tracking payloads to the backend.
  static final wsService = WebSocketService();

  final _userLocation =
      StreamController<LocalizationEngineLocation>.broadcast();

  /// Primary output stream of fused location updates.
  ///
  /// Emits roughly every 1 second (the tick interval), each decision based on
  /// up to the last 6 seconds of data. Each event is the
  /// JSON form of a [LocalizationEngineLocation] — a map with `beaconLocation`,
  /// `gpsLocation`, and `message` keys, any of which may be `null`.
  Stream<Map<String, dynamic>> get userLocation =>
      _userLocation.stream.map((location) => location.toJson());
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

  bool _isWalking = false;

  /// Whether the integrating app currently considers the user to be walking /
  /// navigating. Forwarded to [BLEPositionEstimator.update] as its `walking`
  /// override, which picks the walking (responsive) vs. stationary (heavily
  /// smoothed) filtering profile.
  ///
  /// Defaults to `false`; toggle it at runtime with [setWalking].
  bool get isWalking => _isWalking;

  /// Sets the walking/stationary hint used by [BLEPositionEstimator].
  ///
  /// Call this from the app whenever navigation starts or stops, e.g.
  /// `engine.setWalking(true)` when a route begins and
  /// `engine.setWalking(false)` when it ends or the user goes idle. The new
  /// value applies to the next position update on both the main location loop
  /// and [estimatorLocationStream].
  void setWalking(bool walking) {
    _isWalking = walking;
  }

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
  ///
  /// Set [skipAdapterSetup] only from a headless/background isolate after the
  /// foreground Activity has already granted permissions and enabled the GPS
  /// and Bluetooth adapters. It defaults to `false` for normal app usage.
  /// [localizationMode] controls which adapters, native scanners, and event
  /// streams are activated. It defaults to GPS and BLE together.
  LocalizationEngine(
    String venueName, {
    String? baseURL,
    Map<String, Map<int, Map<String, dynamic>>>? floorConfig,
    bool skipAdapterSetup = false,
    this.localizationMode = LocalizationMode.bothGPSandBLE,
    this.stopAt,
    this.surroundingDeviceScanInterval = const Duration(seconds: 10),
  })  : _skipAdapterSetup = skipAdapterSetup,
        _baseURL = baseURL {
    if (surroundingDeviceScanInterval <= Duration.zero) {
      throw ArgumentError.value(
        surroundingDeviceScanInterval,
        'surroundingDeviceScanInterval',
        'Must be greater than zero.',
      );
    }
    LocalizationEngine.floorConfig = floorConfig;
    AppConfig.url = baseURL;
    unawaited(init(venueName: venueName));
  }

  /// Starts (or re-starts) scanning, the resolution loop, and tracking for
  /// [venueName].
  ///
  /// Called automatically by the constructor — you normally don't invoke this
  /// directly. Use [restart] to cleanly re-initialize an existing instance.
  Future<void> init({required String venueName}) async {
    if (_isDisposed) return;
    print("init called of localization");
    _venueName = venueName;
    _runId++;
    await _startScanning();
    if (_isDisposed) {
      await _stopScanning();
      return;
    }
    _locationLoopTask = _getCurrentLocation(runId: _runId);
    unawaited(_trackUserLocation());
  }

  static void setFloorConfig(
      Map<String, Map<int, Map<String, dynamic>>>? updatedFloorConfig) {
    print("updatedFloorConfig ${updatedFloorConfig}");
    floorConfig = updatedFloorConfig;
  }

  /// Cleanly tears down the current run and re-initializes for [venueName].
  ///
  /// Cancels in-flight loops and subscriptions, resets internal state, clears
  /// the GPS buffer, and reconnects the WebSocket. Call this after the user
  /// grants previously denied permissions or to switch venues.
  Future<void> restart({required String venueName}) async {
    if (_isDisposed) {
      throw StateError('A disposed LocalizationEngine cannot be restarted.');
    }
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

  Future<_AdapterSetupResult> _setupRequiredAdapters() async {
    if (_skipAdapterSetup) return const _AdapterSetupResult.success();

    try {
      final locationPermissionResult = await _setupLocationPermission();
      if (!locationPermissionResult.success) return locationPermissionResult;

      if (_usesGps) {
        final gpsResult = await _setupGpsAdapter();
        if (!gpsResult.success) return gpsResult;
      }
      if (_usesBle) {
        final bleResult = await _setupBleAdapter();
        if (!bleResult.success) return bleResult;
      }
      return const _AdapterSetupResult.success();
    } catch (error) {
      return _AdapterSetupResult.failure(
        'Unexpected error while setting up adapters: $error',
      );
    }
  }

  Future<_AdapterSetupResult> _setupLocationPermission() async {
    final permission = await AdapterManager.requestLocationPermission();
    if (!permission.isGranted) {
      return _AdapterSetupResult.failure(
        permission.isPermanentlyDenied
            ? 'Location permission permanently denied. Please enable it in settings.'
            : 'Location permission denied.',
        permissionDenied: true,
      );
    }
    return const _AdapterSetupResult.success();
  }

  Future<_AdapterSetupResult> _setupGpsAdapter() async {
    final enabled = await AdapterManager.isGpsEnabled() ||
        await AdapterManager.promptEnableGps();
    return enabled
        ? const _AdapterSetupResult.success()
        : const _AdapterSetupResult.failure(
            'GPS not enabled. Please enable location services.',
          );
  }

  Future<_AdapterSetupResult> _setupBleAdapter() async {
    final permission = await AdapterManager.requestBluetoothPermission();
    if (!permission.isGranted) {
      return _AdapterSetupResult.failure(
        permission.isPermanentlyDenied
            ? 'Bluetooth permission permanently denied. Please enable it in settings.'
            : 'Bluetooth permission denied.',
        permissionDenied: true,
      );
    }

    final enabled = await AdapterManager.isBluetoothEnabled() ||
        await AdapterManager.promptEnableBluetooth();
    return enabled
        ? const _AdapterSetupResult.success()
        : const _AdapterSetupResult.failure(
            'Bluetooth not enabled. Please enable Bluetooth.',
          );
  }

  Future<void> _initializeBleVenue() async {
    _localization = InitialLocalization(_venueName);
    await _localization!.parseBeaconMap(_venueName);
  }

  Future<void> _startScanning() async {
    if (_isDisposed) return;
    if (_isScanning) {
      await _stopScanning();
    }

    final adapterResult = await _setupRequiredAdapters();
    if (_isDisposed) return;
    if (!adapterResult.success) {
      final error =
          adapterResult.error ?? 'Unable to set up required adapters.';
      if (adapterResult.permissionDenied) {
        throw PermissionException(error);
      }
      throw AdapterException(error);
    }

    try {
      if (_usesBle) {
        await _initializeBleVenue();
        if (_isDisposed) return;
      }
      if (_usesGps) {
        await _methodChannel.invokeMethod(
          'startGpsScan',
          _nativeSessionConfiguration,
        );
        if (_isDisposed) {
          await _methodChannel.invokeMethod<void>('stopGpsScan');
          return;
        }
        initGpsStream();
      }
      if (_usesBle) {
        await _methodChannel.invokeMethod(
          'startScan',
          _nativeSessionConfiguration,
        );
        if (_isDisposed) {
          await _methodChannel.invokeMethod<void>('stopScan');
          return;
        }
        initBleStream();
        initSurroundingDeviceStream();
        initEstimatorLocationStream();
      }
      _isScanning = true;
    } catch (error, stackTrace) {
      try {
        await _stopScanning();
      } catch (cleanupError) {
        debugPrint(
            'Failed to clean up after scan startup error: $cleanupError');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Map<String, Object?> get _nativeSessionConfiguration => <String, Object?>{
        'venueName': _venueName,
        'baseUrl': _baseURL,
        'mode': localizationMode.name,
        'stopAt': stopAt?.millisecondsSinceEpoch,
      };

  Future<void> _stopScanning() async {
    if (_usesBle) {
      await _methodChannel.invokeMethod('stopScan');
      await _stopEstimatorLocationStream();
      _stopSurroundingDeviceStream();
    }
    if (_usesGps) {
      await _methodChannel.invokeMethod('stopGpsScan');
    }
    await _bleSubscription?.cancel();
    _bleSubscription = null;
    await _gpsSubscription?.cancel();
    _gpsSubscription = null;
    _isScanning = false;
    // A restart rebuilds every stream a simulation was riding on, so the flag
    // must not survive it — otherwise live BLE stays gated off with nothing
    // left to inject in its place.
    if (_isSimulating) {
      _isSimulating = false;
      print('LocalizationEngine: simulation cleared by scan teardown');
    }
  }

  /// Permanently stops this engine and releases its Dart and native resources.
  ///
  /// A disposed instance cannot be restarted. Repeated calls are safe.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _isScanning = false;
    _runId++;

    await _trackingSubscription?.cancel();
    _trackingSubscription = null;

    await _bleSubscription?.cancel();
    _bleSubscription = null;
    await _gpsSubscription?.cancel();
    _gpsSubscription = null;
    await _stopEstimatorLocationStream();
    _stopSurroundingDeviceStream();

    await _safeStopNativeScanner('stopScan');
    await _safeStopNativeScanner('stopGpsScan');

    await _locationLoopTask;
    _locationLoopTask = null;

    wsService.disconnect();

    await _bleController.close();
    await _gpsController.close();
    await _userLocation.close();
    await _estimatorLocationController.close();
    await _surroundingDeviceController.close();
  }

  Future<void> _safeStopNativeScanner(String method) async {
    try {
      await _methodChannel.invokeMethod<void>(method);
    } on MissingPluginException {
      // The native engine may already have detached during shutdown.
    } on PlatformException catch (error) {
      debugPrint('Failed to invoke $method during disposal: $error');
    }
  }

  final _bleController = StreamController<Map<String, dynamic>?>.broadcast();

  /// Raw, RSSI-filtered BLE scan results (`|rssi|` kept within `55`–`110`).
  ///
  /// Intended for diagnostics, logging, or signal-strength UIs. For resolved
  /// positions use [userLocation] instead.
  Stream<Map<String, dynamic>?> get bluetoothScanResults =>
      _bleController.stream;

  StreamSubscription? _bleSubscription;

  void initBleStream() {
    _bleSubscription ??=
        _bleEventChannel.receiveBroadcastStream().listen((event) {
      try {
        // Simulation owns the stream while it runs: a replayed walk must not
        // be corrected by beacons the phone can actually hear right now.
        if (_isSimulating) return;
        final List<dynamic> rawList = event as List;
        for (var entry in rawList) {
          final map = Map<String, dynamic>.from(entry);
          final name = map['name'];
          if (name is! String || !name.toLowerCase().startsWith('iw')) {
            _surroundingDeviceAggregator.add(map);
            continue;
          }
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

  // ── Simulation / recorded-log replay ──────────────────────────────────

  bool _isSimulating = false;

  /// True while [injectBleScan] is the only thing feeding
  /// [bluetoothScanResults]. See [startSimulation].
  bool get isSimulating => _isSimulating;

  /// Hands the BLE input over to [injectBleScan] so a recorded session can be
  /// pushed through the real pipeline — [bluetoothScanResults], the per-second
  /// estimator loop, and out of [estimatorLocationStream] — instead of the
  /// consumer replaying the *decisions* a recording happened to reach.
  ///
  /// The native scanner keeps running (stopping it would need a full
  /// [restart] to come back); its readings are dropped at the stream boundary
  /// while simulating, so beacons the phone can really hear cannot correct a
  /// walk that was recorded somewhere else.
  ///
  /// Loads the venue beacon map first if startup never got that far. A
  /// simulation brings its own readings, so it needs neither radio — but
  /// [_startScanning] sets the adapters up *before* it loads the beacon map,
  /// and throws when Bluetooth or location services are off. That leaves
  /// [_localization] null, and a null beacon map means the estimator has
  /// nothing to place a reading against: every fix comes back null, however
  /// good the injected data is. Loading it here is a plain network fetch and
  /// needs no adapter, so a replay runs on a phone with both radios switched
  /// off — which is the whole point of testing at a desk.
  Future<void> startSimulation() async {
    if (_isSimulating) return;
    _isSimulating = true;
    if (_localization == null) {
      print('LocalizationEngine: simulation needs the venue beacon map and '
          'startup never loaded it (adapters off?) — fetching it now');
      try {
        await _initializeBleVenue();
      } catch (error) {
        print('LocalizationEngine: simulation could not load the beacon map '
            'for "$_venueName": $error — every fix will be null');
      }
    }
    // Whatever the estimator has buffered describes where the phone actually
    // is. A replay begins somewhere else, so that state is not just stale, it
    // is wrong.
    _resetSimulationBatching();
    resetEstimatorStream();
    initEstimatorLocationStream();
    print('LocalizationEngine: simulation ON — live BLE dropped, '
        'injectBleScan drives estimatorLocationStream '
        '(${_localization?.apibeaconmap.length ?? 0} beacons)');
  }

  /// Returns the engine to live scanning and clears the estimator state the
  /// replay built up.
  void stopSimulation() {
    if (!_isSimulating) return;
    // Whatever is in the open bucket is a real second of the recording, so it
    // is resolved before the run is declared over — otherwise the last fix of
    // every replay is silently dropped.
    if (_simBuffer.isNotEmpty) _simulationFlush(_simBucket);
    _isSimulating = false;
    _resetSimulationBatching();
    resetEstimatorStream();
    print('LocalizationEngine: simulation OFF — live BLE resumed');
  }

  /// Feeds one recorded BLE reading into [bluetoothScanResults] as though the
  /// scanner had just reported it. No-op unless [startSimulation] was called.
  ///
  /// [scan] takes the shape the native scanner emits and the shape a session
  /// log records under `scanData`: at minimum `name` (an `IW…` beacon) and
  /// `rssi`. The same name/RSSI gate as the live path applies, so a replay
  /// sees exactly the readings a live run would have seen.
  ///
  /// The reading is stamped with [timestamp], defaulting to now. A replay
  /// passes the instant its schedule says the reading was due — the recorded
  /// detection times mapped onto this run by a single offset — so every gap
  /// between readings is the one the beacons were really heard at, down to the
  /// milliseconds between two beacons in the same scan flush. The recorded
  /// value itself cannot be used directly: the estimator evicts on a rolling
  /// window measured against the wall clock, so a stamp from the day of the
  /// recording would be discarded the moment it arrived. It is preserved under
  /// `recordedTimestamp`.
  ///
  /// Returns whether the reading was accepted.
  bool injectBleScan(Map<String, dynamic> scan, {DateTime? timestamp}) {
    if (!_isSimulating) {
      print('injectBleScan ignored: call startSimulation() first');
      return false;
    }
    if (_isDisposed || _bleController.isClosed) return false;

    final name = scan['name'];
    if (name is! String || !name.toLowerCase().startsWith('iw')) {
      _simRejected++;
      return false;
    }

    final rawRssi = scan['rssi'];
    final num? rssi =
        rawRssi is num ? rawRssi : num.tryParse(rawRssi?.toString() ?? '');
    if (rssi == null) {
      _simRejected++;
      return false;
    }
    final double magnitude = rssi.abs().toDouble();
    if (magnitude < 50 || magnitude > 110) {
      _simRejected++;
      return false;
    }

    final DateTime at = timestamp ?? DateTime.now();
    final reading = Map<String, dynamic>.from(scan)
      ..['rssi'] = rssi.round()
      ..['timestamp'] = at.millisecondsSinceEpoch
      ..['simulated'] = true;
    final recorded = scan['timestamp'];
    if (recorded != null) reading['recordedTimestamp'] = recorded;

    _bleController.add(reading);
    _simInjected++;
    _simulationIngest(reading, at);
    return true;
  }

  // ── Deterministic batching for a simulation ───────────────────────────
  //
  // Live, the estimator loop cuts a batch every wall-clock second and a
  // reading joins whichever bucket happens to be open when it arrives. That is
  // right for a real scanner and wrong for a replay: the timer's phase is set
  // when the loop starts, at an arbitrary offset from the recording's own
  // schedule, so a reading due a millisecond before a boundary on one run
  // falls after it on the next and lands in a different batch. Two replays of
  // one file then disagree — measured at 0.68m median and 5m at p90, with the
  // very first fix already resolving to a different beacon — which is enough
  // to bury the effect of an algorithm change you are trying to measure.
  //
  // So while simulating, the buckets are cut on the *readings'* own clock,
  // anchored to the first reading of the run. Bucket membership is then a pure
  // function of the recorded spacing: identical on every replay of a file, at
  // any playback speed, however much the driver jitters.

  static const Duration _simBatchInterval = Duration(seconds: 1);

  /// Timestamp of the first reading injected this run — the origin of the
  /// bucket grid.
  DateTime? _simBatchAnchor;

  /// Index of the bucket currently accepting readings.
  int _simBucket = 0;

  final List<Map<String, dynamic>> _simBuffer = [];

  /// The instant the estimator should believe it is, while a simulation batch
  /// is being resolved. Null outside a simulation, where the estimator reads
  /// the real clock.
  DateTime? _simClock;

  void _simulationIngest(Map<String, dynamic> reading, DateTime at) {
    final anchor = _simBatchAnchor ??= at;
    final bucket =
        at.difference(anchor).inMicroseconds ~/ _simBatchInterval.inMicroseconds;
    // Closing a bucket is driven by the arrival of a reading that belongs to a
    // later one, so a silent stretch in the recording closes every bucket it
    // spans at once. Those empty buckets are emitted, not skipped: a second
    // that resolved nothing is a result, and dropping them would make a sparse
    // recording look like a dense one.
    while (_simBucket < bucket) {
      _simulationFlush(_simBucket);
      _simBucket++;
    }
    _simBuffer.add(reading);
  }

  /// Resolves one bucket and emits its result on [estimatorLocationStream].
  void _simulationFlush(int bucket) {
    final anchor = _simBatchAnchor;
    if (anchor == null) return;
    // The instant the bucket closed, mirroring the live loop, whose timer
    // fires at the end of the second it collected.
    final closedAt = anchor.add(_simBatchInterval * (bucket + 1));
    final batch = List<Map<String, dynamic>>.from(_simBuffer);
    _simBuffer.clear();

    _simClock = closedAt;
    if (_estimatorStreamEstimator == null && _localization != null) {
      resetEstimatorStream();
    }
    final scanData = groupByDevice(batch);
    final filteredData = _localization?.filterBeacons(scanData) ?? scanData;
    final fix = _resolveWithEstimator(filteredData,
        estimator: _estimatorStreamEstimator, now: closedAt);
    _logSimulationTick(scanData, fix);
    _estimatorLocationController.add(fix);
  }

  /// The recorded instant of the bucket being resolved right now, or null
  /// outside a simulation.
  DateTime? get simulationClock => _simClock;

  /// How far into the run that bucket closed.
  ///
  /// This is the value to key a replay's output on when comparing two runs:
  /// it counts from the run's own first reading, so it is identical on every
  /// replay of a file, while the wall-clock instant obviously is not.
  Duration? get simulationElapsed {
    final clock = _simClock, anchor = _simBatchAnchor;
    if (clock == null || anchor == null) return null;
    return clock.difference(anchor);
  }

  void _resetSimulationBatching() {
    _simBatchAnchor = null;
    _simBucket = 0;
    _simBuffer.clear();
    _simClock = null;
  }

  int _simInjected = 0;
  int _simRejected = 0;

  /// Says, once a second while simulating, which gate a missing fix died at.
  ///
  /// Every tick of the estimator loop can come back null, and the reason is
  /// one of five very different things — nothing injected, the beacons are not
  /// in this venue's map, they are in it but carry no floor-plan coordinates,
  /// or the readings were fine and the algorithm itself declined. Reading that
  /// off a silent null stream is guesswork, so it is spelled out here.
  void _logSimulationTick(
      Map<String, List<MapEntry<DateTime, int>>> grouped,
      BeaconPointLocation? fix) {
    final injected = _simInjected;
    final rejected = _simRejected;
    _simInjected = 0;
    _simRejected = 0;

    final db = _localization?.apibeaconmap;
    if (db == null) {
      print('sim tick: venue beacon map not loaded — every fix will be null');
      return;
    }

    final unknown = <String>[];
    final noCoords = <String>[];
    final usable = <String>[];
    for (final name in grouped.keys) {
      final b = db[name];
      if (b == null) {
        unknown.add(name);
      } else if (b.coordinateX == null ||
          b.coordinateY == null ||
          b.floor == null ||
          b.buildingID == null) {
        noCoords.add(name);
      } else {
        usable.add(name);
      }
    }
    final readings =
        grouped.values.fold<int>(0, (n, entries) => n + entries.length);

    final outcome = fix == null
        ? (usable.isEmpty
            ? 'NO FIX — nothing usable reached the estimator'
            : 'NO FIX — estimator declined on ${usable.length} usable beacon(s)')
        : 'fix ${fix.bid}/${fix.floor} on ${fix.beacons.first} (${fix.rssi})';

    print('sim tick: injected $injected'
        '${rejected > 0 ? ' (+$rejected rejected)' : ''}'
        ', $readings readings / ${grouped.length} beacons'
        ' · usable ${usable.length}$usable'
        '${unknown.isEmpty ? '' : ' · NOT IN VENUE MAP ${unknown.length}$unknown'}'
        '${noCoords.isEmpty ? '' : ' · NO COORDINATES ${noCoords.length}$noCoords'}'
        ' -> $outcome');
  }

  /// Rebuilds the estimator behind [estimatorLocationStream], dropping its
  /// rolling window, EMA position and floor memory. Call it when the readings
  /// about to arrive belong to a different walk than the ones already in it.
  void resetEstimatorStream() {
    final localization = _localization;
    _estimatorStreamEstimator = localization == null
        ? null
        : BLEPositionEstimator(
            beaconDb: localization.apibeaconmap,
            connectorAnchors: _connectorAnchors,
            // Reads the recorded instant while a simulation is running, so the
            // estimator's own clock reads (the connector lock's expiry, the
            // proximity timers) advance with the recording too — not just the
            // `now` handed to update(). Falls through to the real clock live.
            clock: () => _simClock ?? DateTime.now(),
          );
  }

  Map<String, Map<int, Map<String, Set<String>>>>? _connectorAnchors;

  /// The connector anchors the estimators are currently built with, or null
  /// while they are deriving their own. See [setConnectorAnchors].
  Map<String, Map<int, Map<String, Set<String>>>>? get connectorAnchors =>
      _connectorAnchors;

  /// Supplies `{building: {floor: {connectorId: beacon names}}}` for the lift /
  /// escalator / stairs anchors, overriding what [BLEPositionEstimator] would
  /// derive on its own.
  ///
  /// Left unset, the estimator reads the connector off each *beacon*
  /// (`element.subType` and friends). Venues that tag their connectors on
  /// landmarks instead leave those beacon fields empty, so that derivation
  /// yields nothing and the post-floor-change connector lock never engages.
  /// The host app knows its landmarks, so it can build the map properly and
  /// hand it over here.
  ///
  /// Pass null to go back to the estimator's own derivation.
  ///
  /// An estimator bakes its anchors in at construction, so both are rebuilt —
  /// which costs their rolling window and EMA state. Identical anchors are
  /// therefore ignored rather than re-applied: this is safe to call on every
  /// navigation start without resetting a walk in progress.
  void setConnectorAnchors(
      Map<String, Map<int, Map<String, Set<String>>>>? anchors) {
    if (_sameConnectorAnchors(_connectorAnchors, anchors)) return;
    _connectorAnchors = anchors;
    // Dropped rather than rebuilt: the main loop's estimator is created lazily
    // on its next fix, and doing it here would build one before the beacon map
    // is necessarily loaded.
    _positionEstimator = null;
    resetEstimatorStream();
    final connectors = anchors == null
        ? 0
        : anchors.values
            .expand((floors) => floors.values)
            .fold<int>(0, (n, groups) => n + groups.length);
    print('LocalizationEngine: connector anchors set — '
        '${anchors == null ? "cleared, estimator derives its own" : "$connectors connectors across ${anchors.length} building(s)"}');
  }

  bool _sameConnectorAnchors(
      Map<String, Map<int, Map<String, Set<String>>>>? a,
      Map<String, Map<int, Map<String, Set<String>>>>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (final building in a.entries) {
      final other = b[building.key];
      if (other == null || other.length != building.value.length) return false;
      for (final floor in building.value.entries) {
        final otherGroups = other[floor.key];
        if (otherGroups == null || otherGroups.length != floor.value.length) {
          return false;
        }
        for (final group in floor.value.entries) {
          final otherNames = otherGroups[group.key];
          if (otherNames == null ||
              otherNames.length != group.value.length ||
              !otherNames.containsAll(group.value)) return false;
        }
      }
    }
    return true;
  }

  final _surroundingDeviceAggregator = SurroundingDeviceRssiAggregator();
  final _surroundingDeviceController =
      StreamController<Map<String, int>>.broadcast();
  Timer? _surroundingDeviceTimer;
  Map<String, int>? _pendingSurroundingDevices;

  /// Median RSSI per BLE advertiser seen during each configured window.
  ///
  /// Keys are platform BLE identifiers and are not permanent device IDs. This
  /// stream contains BLE advertisers of any kind; identifying host-app phones
  /// specifically requires those apps to advertise a dedicated service UUID.
  Stream<Map<String, int>> get surroundingDeviceSnapshots =>
      _surroundingDeviceController.stream;

  void initSurroundingDeviceStream() {
    if (_surroundingDeviceTimer != null) return;
    _surroundingDeviceTimer = Timer.periodic(
      surroundingDeviceScanInterval,
      (_) => _emitSurroundingDeviceSnapshot(),
    );
  }

  void _emitSurroundingDeviceSnapshot() {
    final devices = _surroundingDeviceAggregator.takeMedianSnapshot();
    if (_isDisposed) return;

    _surroundingDeviceController.add(Map<String, int>.unmodifiable(devices));
    _pendingSurroundingDevices = Map<String, int>.unmodifiable(devices);
  }

  void _stopSurroundingDeviceStream() {
    _surroundingDeviceTimer?.cancel();
    _surroundingDeviceTimer = null;
    _surroundingDeviceAggregator.clear();
    _pendingSurroundingDevices = null;
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
        : BLEPositionEstimator(
            beaconDb: localization.apibeaconmap,
            connectorAnchors: _connectorAnchors,
            clock: () => _simClock ?? DateTime.now(),
          );

    // Buffer of readings received during the current 1-second interval.
    final List<Map<String, dynamic>> buffer = [];

    _estimatorBleSubscription = bluetoothScanResults.listen((data) {
      // A simulation cuts its own batches on the recorded clock — see
      // [_simulationIngest]. Buffering here as well would hand the same
      // readings to the estimator twice.
      if (data != null && !_isSimulating) buffer.add(data);
    });

    _estimatorTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isSimulating) return;
      // Snapshot and clear the previous second's readings atomically.
      final batch = List<Map<String, dynamic>>.from(buffer);
      buffer.clear();

      // The loop can outlive the state it was built on: it is started before
      // the venue is guaranteed loaded, and `??=` in the setup below leaves a
      // null estimator behind for good if the map was not ready then.
      if (_estimatorStreamEstimator == null && _localization != null) {
        resetEstimatorStream();
      }
      final scanData = groupByDevice(batch);
      final filteredData = _localization?.filterBeacons(scanData) ?? scanData;
      final fix = _resolveWithEstimator(filteredData,
          estimator: _estimatorStreamEstimator);
      if (_isSimulating) _logSimulationTick(scanData, fix);
      _estimatorLocationController.add(fix);
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
    _gpsSubscription ??=
        _gpsEventChannel.receiveBroadcastStream().listen((event) {
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

  Future<void> _getCurrentLocation({required int runId}) async {
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

    // Listen only to the data sources enabled by the selected mode. These are
    // internal broadcast streams; the platform event streams are opened by
    // initBleStream/initGpsStream during startup.
    final bleSubscription = _usesBle
        ? bluetoothScanResults.listen((data) {
            if (data != null) bleData.add(data);
          })
        : null;

    final gpsSubscription = _usesGps
        ? gpsScanResults.listen((data) {
            if (data != null) gpsData.add(data);
          })
        : null;

    Future<void> collectAndEmit() async {
      BeaconPointLocation? beaconLocation;
      GPSLocation? gpsLocation;
      // Wait one tick for fresh data to arrive.
      await Future.delayed(const Duration(seconds: tickSeconds));
      if (_isDisposed || runId != _runId) return;

      // Snapshot and clear the 1-second increment atomically for this tick.
      final now = DateTime.now();
      final bleIncrement = List<Map<String, dynamic>>.from(bleData);
      final gpsIncrement = List<Map<String, dynamic>>.from(gpsData);
      bleData.clear();
      gpsData.clear();

      try {
        if (_usesBle) {
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

        if (_usesGps) {
          for (var data in gpsIncrement) {
            _gpsBuffer.add(data['latitude'], data['longitude']);
          }
          List<double>? gpsBufferLocation =
              _gpsBuffer.getWindowedRobustPosition(
                  const Duration(seconds: windowSeconds));
          if (gpsBufferLocation != null &&
              (bestFloor == null || bestFloor == 0)) {
            gpsLocation = GPSLocation(
              latitude: gpsBufferLocation[0],
              longitude: gpsBufferLocation[1],
            );
          }
        }

        print("adding userLocation in collect&emit");

        if (!_isDisposed) {
          _userLocation.add(LocalizationEngineLocation(
            beaconLocation: beaconLocation,
            gpsLocation: gpsLocation,
          ));
        }
      } on StateError {
        if (_usesGps) {
          List<double>? gpsBufferLocation =
              _gpsBuffer.getWindowedRobustPosition(
                  const Duration(seconds: windowSeconds));
          if (gpsBufferLocation != null) {
            gpsLocation = GPSLocation(
              latitude: gpsBufferLocation[0],
              longitude: gpsBufferLocation[1],
            );
          }
        }
        if (!_isDisposed) {
          _userLocation.add(LocalizationEngineLocation(
            beaconLocation: beaconLocation,
            gpsLocation: gpsLocation,
          ));
        }
      } on AdapterException {
        await bleSubscription?.cancel();
        await gpsSubscription?.cancel();
        rethrow;
      } on PermissionException {
        await bleSubscription?.cancel();
        await gpsSubscription?.cancel();
        rethrow;
      } catch (e) {
        print("error in collect and emmit $e");
      }
    }

    while (_isScanning && runId == _runId) {
      try {
        await collectAndEmit();
      } catch (e) {
        print("error in getCurrent Location gpsSubscriptionDebuggggg ${e}");
      }
    }

    await bleSubscription?.cancel();
    await gpsSubscription?.cancel();
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
      {BLEPositionEstimator? estimator, DateTime? now}) {
    final localization = _localization;
    if (localization == null) return null;

    // Lazily build the estimator over the loaded beacon map.
    final activeEstimator = estimator ??
        (_positionEstimator ??= BLEPositionEstimator(
          beaconDb: localization.apibeaconmap,
          connectorAnchors: _connectorAnchors,
        ));

    // Flatten grouped scan data into individual timestamped readings.
    final readings = <BleReading>[];
    filteredData.forEach((name, entries) {
      for (final e in entries) {
        readings.add(BleReading(name: name, rssi: e.value, timestamp: e.key));
      }
    });

    // [now] is the instant this batch closed, and it reaches the estimator
    // through the clock injected at construction rather than as an argument:
    // the estimator takes its time from a single `_clock()` read per update,
    // so setting [_simClock] before this call is what makes window eviction
    // and the silence timers advance with the recording instead of with
    // however long the phone took to get here. Live, that clock is the real
    // one and [now] is null. It is still used below to stamp the fix.
    final pos = activeEstimator.update(readings, walking: _isWalking);
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
        latitude: pos.smoothLat ?? double.parse(rank1.properties!.latitude!),
        longitude: pos.smoothLon ?? double.parse(rank1.properties!.longitude!),
        beacons: [pos.rank1Beacon],
        rssi: pos.rank1Rssi.toDouble(),
        bestFloor: pos.floor,
        pendingFloor: pos.pendingFloor,
        timeStamp: now ?? DateTime.now());
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
      if (id == null) {
        return _generateFallbackId();
      } else {
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

  Future<void> _trackUserLocation() async {
    print("_trackUserLocation");
    final deviceId = await _getDeviceId();
    if (_isDisposed) return;
    print("_trackUserLocation $deviceId");
    wsService.connect();

    await _trackingSubscription?.cancel();
    _trackingSubscription = _userLocation.stream.listen((data) {
      print("recieved data in _trackUserLocation");
      BeaconPointLocation? beaconLocation = data.beaconLocation;
      GPSLocation? gpsLocation = data.gpsLocation;
      if (gpsLocation == null && beaconLocation == null) return;

      final payload = TrackingPayload(
        id: deviceId,
        t: DateTime.now().millisecondsSinceEpoch,
        pts: {
          if (beaconLocation != null)
            'nb': [
              beaconLocation.x,
              beaconLocation.y,
              int.parse(beaconLocation.latitude.toString().replaceAll('.', '')),
              int.parse(
                  beaconLocation.longitude.toString().replaceAll('.', '')),
              beaconLocation.floor,
              1,
            ],
          if (gpsLocation != null)
            'gp': [
              null,
              null,
              int.parse(gpsLocation.latitude.toString().replaceAll('.', '')),
              int.parse(gpsLocation.longitude.toString().replaceAll('.', '')),
              beaconLocation?.floor??0,
              2,
            ],
        },
        venueName: _venueName,
        surroundingDevices: _takePendingSurroundingDevices(),
      );

      wsService.sendTracking(payload);
    });
  }

  Map<String, int>? _takePendingSurroundingDevices() {
    final devices = _pendingSurroundingDevices;
    _pendingSurroundingDevices = null;
    return devices;
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
