import 'package:flutter/services.dart';

/// Handles all BLE scanning channel communication
class BleScanner {
  static const MethodChannel _methodChannel =
      MethodChannel('localization_engine');
  static const EventChannel _bleEventChannel =
      EventChannel('ble_scan_stream');

  final Map<String, dynamic> _params;

  BleScanner({
    Duration? frequency,
    Duration? bufferSize,
    Duration? timeout,
    bool immediateEmit = false,
  }) : _params = {
          'frequency': frequency?.inMilliseconds,
          'bufferSize': bufferSize?.inMilliseconds,
          'timeout': timeout?.inMilliseconds,
          'immediateEmit': immediateEmit,
        };

  Future<void> initialize() =>
      _methodChannel.invokeMethod('initializeScan', _params);

  Future<void> start() => _methodChannel.invokeMethod('startScan');

  Future<void> stop() => _methodChannel.invokeMethod('stopScan');

  /// Raw BLE event broadcast stream
  Stream<List<dynamic>> get rawStream =>
      _bleEventChannel
          .receiveBroadcastStream()
          .where((event) => event is List)
          .cast<List<dynamic>>();

  /// Filtered stream of beacon RSSI entries (only "iw" devices)
  Stream<BeaconScanData> get beaconStream =>
      rawStream.map(BeaconScanData.fromRawList);
}

/// Structured container for a single BLE scan result
class BeaconScanData {
  final Map<String, List<MapEntry<DateTime, int>>> readings;

  const BeaconScanData(this.readings);

  bool get isEmpty => readings.isEmpty;

  factory BeaconScanData.fromRawList(List<dynamic> rawList) {
    final Map<String, List<MapEntry<DateTime, int>>> data = {};

    for (final entry in rawList) {
      final map = Map<String, dynamic>.from(entry as Map);
      final device = map['name'] as String;
      if (!device.toLowerCase().contains('iw')) continue;

      final timestamp = DateTime.parse(map['timestamp']);
      final rssi = map['rssi'] as int;

      data.putIfAbsent(device, () => []).add(MapEntry(timestamp, rssi));
    }

    return BeaconScanData(data);
  }
}
