import 'package:flutter/services.dart';
import 'localizationAlgorithm/initialLocalization.dart';

class LocalizationEngine {
  static const MethodChannel _methodChannel = MethodChannel('localization_engine');
  static const EventChannel _eventChannel = EventChannel('ble_scan_stream');
  static InitialLocalization? _localization;

  static void setVenue(String venueName) {
    _localization = InitialLocalization(venueName: venueName);
  }

  /// Initialize scanning with custom params
  static Future<void> _initializeScanning({
    required Duration frequency,
    required Duration bufferSize,
    required Duration? timeout, // null means no timeout
  }) async {
    final params = {
      'frequency': frequency.inMilliseconds,
      'bufferSize': bufferSize.inMilliseconds,
      'timeout': timeout?.inMilliseconds,
    };
    await _methodChannel.invokeMethod('initializeScan', params);
  }

  static bool _isScanning = false;
  static bool get isScanning => _isScanning;

  static Future<void> startScanning({
     Duration frequency = const Duration(seconds: 6),
     Duration bufferSize = const Duration(seconds: 6),
     Duration? timeout, // null means no timeout
  }) async {
    if (_isScanning) {
      throw StateError('Scanning is already in progress');
    }
    if (_localization == null) {
      throw StateError('Venue must be set before starting scan. Call setVenue() first.');
    }

    _initializeScanning(frequency: frequency, bufferSize: bufferSize, timeout: timeout);
    await _methodChannel.invokeMethod('startScan');
    _isScanning = true;
  }

  static Future<void> stopScanning() async {
    await _methodChannel.invokeMethod('stopScan');
    _isScanning = false;
  }

  /// Stream to listen to periodic scan results
  /// Listen to BLE scan results as a stream of list of devices
  static Stream<Pt?> get scanResults =>
      _eventChannel.receiveBroadcastStream().asyncMap((event) async {
        try {
        final List<dynamic> rawList = event as List;

        final Map<String, List<MapEntry<DateTime, int>>> formattedData = {};

        for (var entry in rawList) {
          final map = Map<String, dynamic>.from(entry);
          final device = map['device'] as String;
          final timestamp =
          DateTime.fromMillisecondsSinceEpoch(map['timestamp']);
          final rssi = map['rssi'] as int;

          formattedData.putIfAbsent(device, () => []);
          formattedData[device]!.add(MapEntry(timestamp, rssi));
        }
          return await _localization?.findLocation(formattedData);
        } catch (e) {
          print('Error processing scan result: $e');
          return null; // or rethrow based on your needs
        }
      }).handleError((error) {
        print('Stream error: $error');
      });

  static Future<void> dispose() async {
    await stopScanning();
    _localization = null;
    _isScanning = false;
  }
}

