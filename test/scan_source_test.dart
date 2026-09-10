import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/src/scan/scan_source.dart';

void main() {
  final config = ScanSessionConfig(
    venueName: 'IITDelhi',
    baseUrl: 'https://example.test',
    mode: 'bothGPSandBLE',
    stopAt: DateTime.fromMillisecondsSinceEpoch(1757337600000),
    flushInterval: const Duration(milliseconds: 250),
  );

  test('native arguments keep the shape the plugin already expects', () {
    expect(config.toPlatformChannelArguments(), <String, Object?>{
      'venueName': 'IITDelhi',
      'baseUrl': 'https://example.test',
      'mode': 'bothGPSandBLE',
      'stopAt': 1757337600000,
    });
  });

  test('the bridge receives scanner tunables and nothing else', () {
    final bridge = config.toBridgeConfiguration();

    expect(bridge['flushIntervalMs'], 250);
    expect(bridge['restartIntervalMs'], 60000);

    // The scanner does not know what a venue is, and the session deadline is
    // policy the engine enforces itself — the whole reason the iOS plugin's
    // persisted-session logic was dropped. Leaking either back across the
    // bridge would put that decision in two places again.
    expect(bridge.containsKey('venueName'), isFalse);
    expect(bridge.containsKey('baseUrl'), isFalse);
    expect(bridge.containsKey('stopAt'), isFalse);
  });

  test('a denied adapter is distinguishable from an unavailable one', () {
    // The engine reports these differently: one is recoverable in system
    // settings, the other by flicking a switch.
    const denied = AdapterReadiness.denied('no');
    const unavailable = AdapterReadiness.unavailable('off');

    expect(denied.isReady, isFalse);
    expect(denied.permissionDenied, isTrue);
    expect(unavailable.isReady, isFalse);
    expect(unavailable.permissionDenied, isFalse);
    expect(const AdapterReadiness.ready().isReady, isTrue);
  });
}
