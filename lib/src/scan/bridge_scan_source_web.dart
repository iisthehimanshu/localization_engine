import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import 'scan_source.dart';

/// The protocol version this consumer understands.
///
/// The host app is compiled into someone else's binary on someone else's
/// release cycle, so an old scanner and a new bundle will meet in the field.
/// Additive payload fields keep this number; anything else raises it, and the
/// mismatch is reported rather than silently misread.
const int kSupportedProtocolVersion = 1;

@JS('__iwayplusScanner')
external _Bridge? get _globalBridge;

/// The object `@iwayplus/react-native-scanner` injects into the page.
extension type _Bridge._(JSObject _) implements JSObject {
  external bool get available;
  external int get protocolVersion;
  external set onEvent(JSFunction value);
  external void ready();
  external void configure(JSAny? config);
  external void start(JSArray<JSString> streams);
  external void stop(JSArray<JSString> streams);
  external void stopAll();
  external void getState();
}

/// [ScanSource] backed by the React Native host app's scanner.
///
/// This is the web half of the arrangement that lets the positioning engine
/// live in a hosted bundle: a browser cannot scan for BLE beacons, so the host
/// app scans and relays readings in, and everything above [ScanSource] is
/// unchanged from the native path.
class BridgeScanSource implements ScanSource {
  BridgeScanSource._(this._bridge);

  final _Bridge _bridge;

  final _bleBatches = StreamController<List<Map<String, dynamic>>>.broadcast();
  final _gpsFixes = StreamController<Map<String, dynamic>>.broadcast();
  final _headings = StreamController<double>.broadcast();
  final _adapterChanges = StreamController<AdapterReadiness>.broadcast();

  Completer<AdapterReadiness>? _pendingState;
  int _lastSequence = 0;
  int _sequenceGaps = 0;
  bool _warnedAboutVersion = false;

  /// Number of times the event sequence skipped.
  ///
  /// A gap means the relay stalled and then burst — a WebView under memory
  /// pressure does exactly that — which matters because RSSI is aggregated
  /// over time windows, and a burst is not the same shape as a steady stream.
  int get sequenceGaps => _sequenceGaps;

  @override
  String get description => 'react native host bridge';

  @override
  bool get providesBle => true;

  /// True when the page is running inside a host app that provides scanning.
  ///
  /// False in a plain browser — opened from a QR code or a desktop — where the
  /// engine should fall back to browser geolocation alone rather than wait
  /// forever for beacons that cannot arrive.
  static bool get isAvailable => _globalBridge?.available ?? false;

  /// Resolves once the bridge exists, or to null if it never appears.
  ///
  /// The bootstrap is injected at document start on iOS, but on Android
  /// react-native-webview evaluates it from `onPageStarted`, which can land
  /// *after* this bundle's own startup code. Reading the global synchronously
  /// therefore works on iOS and intermittently fails on Android — so the
  /// ready event is the only correct way in.
  static Future<BridgeScanSource?> connect({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final existing = _globalBridge;
    if (existing != null) return BridgeScanSource._(existing).._attach();

    final completer = Completer<void>();
    void listener(web.Event _) {
      if (!completer.isCompleted) completer.complete();
    }

    final jsListener = listener.toJS;
    web.window.addEventListener('iwayplusscannerready', jsListener);
    try {
      await completer.future.timeout(timeout, onTimeout: () {});
    } finally {
      web.window.removeEventListener('iwayplusscannerready', jsListener);
    }

    final bridge = _globalBridge;
    if (bridge == null) {
      debugPrint(
        'Iwayplus scanner bridge did not appear within ${timeout.inSeconds}s; '
        'running without host-provided scanning.',
      );
      return null;
    }
    return BridgeScanSource._(bridge).._attach();
  }

  void _attach() {
    _bridge.onEvent = ((JSAny event, JSAny? _) => _onEvent(event)).toJS;
    _bridge.ready();
  }

  void _onEvent(JSAny event) {
    final envelope = _asStringMap(event.dartify());
    if (envelope == null) return;

    final version = (envelope['v'] as num?)?.toInt() ?? 0;
    if (version != kSupportedProtocolVersion && !_warnedAboutVersion) {
      _warnedAboutVersion = true;
      debugPrint(
        'Iwayplus scanner protocol v$version, this bundle understands '
        'v$kSupportedProtocolVersion. Reading what is recognisable.',
      );
    }

    final sequence = (envelope['seq'] as num?)?.toInt() ?? 0;
    if (_lastSequence != 0 && sequence != _lastSequence + 1) {
      _sequenceGaps++;
    }
    _lastSequence = sequence;

    final payload = _asStringMap(envelope['payload']);
    if (payload == null) return;

    switch (envelope['type']) {
      case 'ble':
        _emitBleBatch(payload);
      case 'gps':
        _gpsFixes.add(payload);
      case 'heading':
        final heading = (payload['heading'] as num?)?.toDouble();
        if (heading != null) _headings.add(heading);
      case 'adapter':
        _emitAdapterState(payload);
      case 'error':
        final code = payload['code'];
        final message = payload['message'];
        debugPrint('Iwayplus scanner error $code: $message');
        if (code == 'PERMISSION_DENIED') {
          _completeState(AdapterReadiness.denied('$message'));
        }
      case 'hello':
        debugPrint(
          'Iwayplus scanner ${payload['moduleVersion']} on '
          '${payload['platform']} ${payload['osVersion']}',
        );
    }
  }

  void _emitBleBatch(Map<String, dynamic> payload) {
    final readings = payload['readings'];
    if (readings is! List) return;

    final batch = <Map<String, dynamic>>[];
    for (final reading in readings) {
      final map = _asStringMap(reading);
      if (map != null) batch.add(map);
    }
    if (batch.isNotEmpty) _bleBatches.add(batch);

    // Surfaced rather than swallowed: a non-zero count means the venue is
    // denser than the scanner's configured buffer, which is a tuning problem
    // and not missing hardware.
    final dropped = (payload['dropped'] as num?)?.toInt() ?? 0;
    if (dropped > 0) {
      debugPrint('Iwayplus scanner dropped $dropped readings this window');
    }
  }

  void _emitAdapterState(Map<String, dynamic> payload) {
    final permissions = _asStringMap(payload['permissions']) ?? const {};
    final bluetoothGranted = permissions['bluetooth'] == true;
    final locationGranted = permissions['location'] == true;

    final AdapterReadiness readiness;
    if (!bluetoothGranted || !locationGranted) {
      readiness = const AdapterReadiness.denied(
        'The host app has not been granted Bluetooth and location access.',
      );
    } else if (payload['bluetooth'] != 'on') {
      readiness = AdapterReadiness.unavailable(
        'Bluetooth is ${payload['bluetooth']}.',
      );
    } else if (payload['location'] != 'on') {
      readiness = AdapterReadiness.unavailable(
        'Location services are ${payload['location']}.',
      );
    } else {
      readiness = const AdapterReadiness.ready();
    }

    _adapterChanges.add(readiness);
    _completeState(readiness);
  }

  void _completeState(AdapterReadiness readiness) {
    final pending = _pendingState;
    if (pending != null && !pending.isCompleted) {
      pending.complete(readiness);
    }
  }

  /// Asks the host for adapter state instead of requesting anything.
  ///
  /// Permissions belong to the host app: it owns the manifest entries and the
  /// system prompts, and it is expected to have them granted before this page
  /// is shown. All this can do is report what it finds.
  @override
  Future<AdapterReadiness> prepare({
    required bool ble,
    required bool gps,
  }) async {
    final completer = Completer<AdapterReadiness>();
    _pendingState = completer;
    _bridge.getState();

    return completer.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => const AdapterReadiness.unavailable(
        'The host app did not report scanner state.',
      ),
    );
  }

  @override
  Future<void> startBle(ScanSessionConfig config) async {
    _bridge.configure(config.toBridgeConfiguration().jsify());
    _bridge.start(<JSString>['ble'.toJS].toJS);
  }

  @override
  Future<void> stopBle() async => _bridge.stop(<JSString>['ble'.toJS].toJS);

  @override
  Future<void> startGps(ScanSessionConfig config) async {
    _bridge.configure(config.toBridgeConfiguration().jsify());
    // Heading rides along with GPS: both answer "where is the user facing and
    // standing", and no caller has ever wanted one without the other.
    _bridge.start(<JSString>['gps'.toJS, 'heading'.toJS].toJS);
  }

  @override
  Future<void> stopGps() async =>
      _bridge.stop(<JSString>['gps'.toJS, 'heading'.toJS].toJS);

  @override
  Stream<List<Map<String, dynamic>>> get bleBatches => _bleBatches.stream;

  @override
  Stream<Map<String, dynamic>> get gpsFixes => _gpsFixes.stream;

  @override
  Stream<double> get headings => _headings.stream;

  @override
  Stream<AdapterReadiness> get adapterChanges => _adapterChanges.stream;

  @override
  Future<void> dispose() async {
    _bridge.stopAll();
    await _bleBatches.close();
    await _gpsFixes.close();
    await _headings.close();
    await _adapterChanges.close();
  }
}

/// `dartify()` hands back `Map<Object?, Object?>`; the engine wants string keys.
Map<String, dynamic>? _asStringMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, dynamic v) => MapEntry(key.toString(), v));
  }
  return null;
}
