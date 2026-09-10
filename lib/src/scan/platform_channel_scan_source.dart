import 'dart:async';

import 'package:adapter_manager/adapter_manager.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'scan_source.dart';

/// [ScanSource] backed by the native Flutter plugin.
///
/// This is the path a native Flutter host takes, and it is a faithful
/// extraction of what the engine did inline before the interface existed —
/// same channel names, same method names, same argument shapes — so moving to
/// the interface changes nothing for existing apps.
class PlatformChannelScanSource implements ScanSource {
  PlatformChannelScanSource({
    MethodChannel? methodChannel,
    EventChannel? bleEventChannel,
    EventChannel? gpsEventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel('localization_engine'),
        _bleEventChannel =
            bleEventChannel ?? const EventChannel('ble_scan_stream'),
        _gpsEventChannel =
            gpsEventChannel ?? const EventChannel('gps_scan_stream');

  final MethodChannel _methodChannel;
  final EventChannel _bleEventChannel;
  final EventChannel _gpsEventChannel;

  final _adapterChanges = StreamController<AdapterReadiness>.broadcast();

  Stream<List<Map<String, dynamic>>>? _bleBatches;
  Stream<Map<String, dynamic>>? _gpsFixes;

  @override
  String get description => 'native platform channels';

  @override
  bool get providesBle => true;

  @override
  bool get providesHeading => false;

  @override
  Future<AdapterReadiness> prepare({
    required bool ble,
    required bool gps,
  }) async {
    if (ble || gps) {
      final permission = await AdapterManager.requestLocationPermission();
      if (!permission.isGranted) {
        return AdapterReadiness.denied(
          permission.isPermanentlyDenied
              ? 'Location permission permanently denied. Please enable it in settings.'
              : 'Location permission denied.',
        );
      }
    }

    if (gps) {
      final enabled = await AdapterManager.isGpsEnabled() ||
          await AdapterManager.promptEnableGps();
      if (!enabled) {
        return const AdapterReadiness.unavailable(
          'GPS not enabled. Please enable location services.',
        );
      }
    }

    if (ble) {
      final permission = await AdapterManager.requestBluetoothPermission();
      if (!permission.isGranted) {
        return AdapterReadiness.denied(
          permission.isPermanentlyDenied
              ? 'Bluetooth permission permanently denied. Please enable it in settings.'
              : 'Bluetooth permission denied.',
        );
      }
      final enabled = await AdapterManager.isBluetoothEnabled() ||
          await AdapterManager.promptEnableBluetooth();
      if (!enabled) {
        return const AdapterReadiness.unavailable(
          'Bluetooth not enabled. Please enable Bluetooth.',
        );
      }
    }

    return const AdapterReadiness.ready();
  }

  @override
  Future<void> startBle(ScanSessionConfig config) => _methodChannel
      .invokeMethod<void>('startScan', config.toPlatformChannelArguments());

  @override
  Future<void> stopBle() => _safeInvoke('stopScan');

  @override
  Future<void> startGps(ScanSessionConfig config) => _methodChannel
      .invokeMethod<void>('startGpsScan', config.toPlatformChannelArguments());

  @override
  Future<void> stopGps() => _safeInvoke('stopGpsScan');

  /// Stopping tolerates a detached engine: during shutdown the native side may
  /// already be gone, and that is not a failure worth propagating.
  Future<void> _safeInvoke(String method) async {
    try {
      await _methodChannel.invokeMethod<void>(method);
    } on MissingPluginException {
      // Native engine already detached.
    } on PlatformException catch (error) {
      debugPrint('Failed to invoke $method: $error');
    }
  }

  @override
  Stream<List<Map<String, dynamic>>> get bleBatches =>
      _bleBatches ??= _bleEventChannel
          .receiveBroadcastStream()
          .where((event) => event is List)
          .map((event) => (event as List)
              .map((entry) => Map<String, dynamic>.from(entry as Map))
              .toList(growable: false))
          .asBroadcastStream();

  @override
  Stream<Map<String, dynamic>> get gpsFixes =>
      _gpsFixes ??= _gpsEventChannel
          .receiveBroadcastStream()
          .where((event) => event is Map)
          .map((event) => Map<String, dynamic>.from(event as Map))
          .asBroadcastStream();

  /// Not served by the native channels.
  ///
  /// Heading on this path still comes from `flutter_compass`, which the engine
  /// reads directly. Wiring it through here would mean adding a native heading
  /// channel for no gain — the bridge path is the one that needed it.
  @override
  Stream<double> get headings => const Stream<double>.empty();

  @override
  Stream<AdapterReadiness> get adapterChanges => _adapterChanges.stream;

  @override
  Future<void> dispose() async {
    await _adapterChanges.close();
  }
}
