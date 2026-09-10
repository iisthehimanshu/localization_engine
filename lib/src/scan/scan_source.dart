import 'dart:async';

/// Where the engine gets raw sensor data from.
///
/// The engine used to talk to `MethodChannel('localization_engine')` and two
/// `EventChannel`s directly, which tied it to a native Flutter host. It now
/// runs in two very different places:
///
///   * a native Flutter app, where the platform channels are still the source;
///   * a web bundle inside a React Native WebView, where BLE and GPS arrive
///     over a JavaScript bridge because a browser cannot scan for beacons.
///
/// Both look identical from here. Nothing above this interface knows or cares
/// which one is underneath, so the positioning maths has exactly one
/// implementation rather than one per host.
abstract class ScanSource {
  /// Human-readable name for logs and diagnostics.
  String get description;

  /// Whether this source can deliver BLE advertisements at all.
  ///
  /// False only in a plain browser, where no API exposes beacon
  /// advertisements. Callers use it to decide whether indoor positioning is
  /// even possible before waiting for a fix that can never arrive — the
  /// difference between "no beacons in range" and "beacons are unreachable
  /// here" is not something a timeout can tell them.
  bool get providesBle;

  /// Whether this source relays a compass heading.
  ///
  /// True only for the host bridge, where the app's native compass is
  /// forwarded in. A plain browser reports false: `DeviceOrientation` needs a
  /// gesture-initiated permission prompt that belongs to the page, not to the
  /// engine, so the caller sources heading itself there.
  bool get providesHeading;

  /// Ask for permissions and adapter power-on.
  ///
  /// Returns rather than throws: refusing to scan is a normal outcome the
  /// engine reports to the app, not an exceptional one.
  Future<AdapterReadiness> prepare({required bool ble, required bool gps});

  Future<void> startBle(ScanSessionConfig config);
  Future<void> stopBle();

  Future<void> startGps(ScanSessionConfig config);
  Future<void> stopGps();

  /// Batches of BLE advertisements.
  ///
  /// A batch, not a single reading: the scanner coalesces a window of
  /// advertisements (~250 ms) because a dense venue produces well over 200
  /// readings a second, which is measured — not estimated. Each entry carries
  /// at least `name`, `rssi` and `timestamp`; the bridge adds `device` and
  /// `manufacturerHex`.
  ///
  /// Unfiltered by design. Which advertisers are beacons is venue knowledge,
  /// and it lives in this package rather than in a host app that ships on
  /// someone else's release cycle.
  Stream<List<Map<String, dynamic>>> get bleBatches;

  /// Location fixes carrying at least `latitude` and `longitude`.
  Stream<Map<String, dynamic>> get gpsFixes;

  /// Device heading in degrees, 0–360.
  ///
  /// Previously read straight from `flutter_compass`, which has no web
  /// implementation — the reason heading belongs on this interface at all.
  Stream<double> get headings;

  /// Adapter/permission state changes observed after [prepare].
  Stream<AdapterReadiness> get adapterChanges;

  Future<void> dispose();
}

/// Result of asking for permissions and adapter power.
class AdapterReadiness {
  const AdapterReadiness.ready()
      : isReady = true,
        permissionDenied = false,
        message = null;

  const AdapterReadiness.denied(this.message)
      : isReady = false,
        permissionDenied = true;

  const AdapterReadiness.unavailable(this.message)
      : isReady = false,
        permissionDenied = false;

  final bool isReady;

  /// True when the user refused, as opposed to an adapter simply being off.
  /// The engine surfaces these differently: one is recoverable in settings,
  /// the other by flicking a switch.
  final bool permissionDenied;

  final String? message;
}

/// Everything a scan session needs to know, independent of transport.
class ScanSessionConfig {
  const ScanSessionConfig({
    required this.venueName,
    required this.baseUrl,
    required this.mode,
    this.stopAt,
    this.flushInterval = const Duration(milliseconds: 250),
    this.restartInterval = const Duration(minutes: 1),
    this.gpsInterval = const Duration(seconds: 1),
    this.headingFilterDegrees = 1,
  });

  final String venueName;
  final String baseUrl;
  final String mode;

  /// When the session should end.
  ///
  /// Deliberately enforced here rather than by the scanner. The native iOS
  /// plugin used to own this deadline — and its own persisted session state —
  /// which meant "when does scanning stop" was answered differently on each
  /// platform. It is policy, so it belongs with the engine.
  final DateTime? stopAt;

  /// How long the scanner coalesces advertisements before delivering a batch.
  final Duration flushInterval;

  /// How often the scanner tears the BLE scan down and restarts it. Android
  /// throttles a scan left running too long.
  final Duration restartInterval;

  final Duration gpsInterval;

  /// Suppress heading updates smaller than this. The sensor fires far faster
  /// than positioning needs, and on the bridge every update is a crossing.
  final double headingFilterDegrees;

  /// Shape the native platform channels expect. Unchanged from what the
  /// engine sent before this interface existed.
  Map<String, Object?> toPlatformChannelArguments() => <String, Object?>{
        'venueName': venueName,
        'baseUrl': baseUrl,
        'mode': mode,
        'stopAt': stopAt?.millisecondsSinceEpoch,
      };

  /// Shape the JavaScript bridge expects.
  ///
  /// Only the scanner tunables cross: the bridge scans, it does not know what
  /// a venue is, and `stopAt` is enforced on this side.
  Map<String, Object?> toBridgeConfiguration() => <String, Object?>{
        'flushIntervalMs': flushInterval.inMilliseconds,
        'restartIntervalMs': restartInterval.inMilliseconds,
        'gpsIntervalMs': gpsInterval.inMilliseconds,
        'headingFilterDeg': headingFilterDegrees,
      };
}

/// Thrown when a source is asked for something its transport cannot do.
class ScanSourceUnsupported implements Exception {
  const ScanSourceUnsupported(this.message);
  final String message;
  @override
  String toString() => 'ScanSourceUnsupported: $message';
}
