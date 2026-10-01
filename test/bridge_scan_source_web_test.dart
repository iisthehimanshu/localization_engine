@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/src/scan/bridge_scan_source_web.dart';

/// Installs a stand-in for the object `@iwayplus/react-native-scanner`
/// injects, recording every command the page sends.
///
/// [send] is what the real bootstrap's `send` answers: false when the page is
/// not inside a React Native WebView and the command went nowhere.
void _installBridge({required bool withOpenSettings, bool send = true}) {
  globalContext.callMethod('eval'.toJS, '''
    window.__sent = [];
    window.__iwayplusScanner = {
      available: true,
      protocolVersion: 1,
      set onEvent(fn) {},
      send: function (command) { window.__sent.push(command.cmd); return $send; },
      configure: function (c) { return this.send({ cmd: 'configure' }); },
      start: function (s) { return this.send({ cmd: 'start' }); },
      stop: function (s) { return this.send({ cmd: 'stop' }); },
      stopAll: function () { return this.send({ cmd: 'stopAll' }); },
      getState: function () { return this.send({ cmd: 'getState' }); },
      ready: function () { return this.send({ cmd: 'ready' }); },
      ${withOpenSettings ? "openSettings: function () { return this.send({ cmd: 'openSettings' }); }," : ''}
    };
  '''.toJS);
}

List<String> get _sent => (globalContext['__sent'] as JSArray<JSString>)
    .toDart
    .map((s) => s.toDart)
    .toList();

/// Like [_installBridge], but records which streams each start/stop named.
void _installStreamRecordingBridge() {
  globalContext.callMethod('eval'.toJS, '''
    window.__sent = [];
    window.__iwayplusScanner = {
      available: true,
      protocolVersion: 1,
      set onEvent(fn) {},
      configure: function (c) { return true; },
      start: function (s) { window.__sent.push('start:' + s.join(',')); return true; },
      stop: function (s) { window.__sent.push('stop:' + s.join(',')); return true; },
      stopAll: function () { return true; },
      getState: function () { return true; },
      ready: function () { return true; },
    };
  '''.toJS);
}

void main() {
  tearDown(() {
    globalContext.delete('__iwayplusScanner'.toJS);
    globalContext.delete('__sent'.toJS);
  });

  test('the compass starts when something listens, with no scan running',
      () async {
    // A QR or picked-landmark fix needs no scan session, and the session may
    // be unable to start at all (Bluetooth off). The puck still has to turn.
    _installStreamRecordingBridge();
    final source = (await BridgeScanSource.connect())!;
    expect(_sent, isEmpty);

    final subscription = source.headings.listen((_) {});
    expect(_sent, ['start:heading']);

    await subscription.cancel();
    expect(_sent, ['start:heading', 'stop:heading']);
  });

  test('stopping GPS leaves the compass running for its listeners', () async {
    _installStreamRecordingBridge();
    final source = (await BridgeScanSource.connect())!;
    final subscription = source.headings.listen((_) {});

    await source.stopGps();

    expect(_sent, ['start:heading', 'stop:gps']);
    await subscription.cancel();
  });

  test('asks the host to open its settings', () async {
    _installBridge(withOpenSettings: true);
    final source = (await BridgeScanSource.connect())!;

    expect(await source.openSettings(), isTrue);
    expect(_sent, contains('openSettings'));
  });

  test('a host built before the command answers false instead of throwing',
      () async {
    // The caller relies on false to fall back, rather than offering a button
    // that silently does nothing.
    _installBridge(withOpenSettings: false);
    final source = (await BridgeScanSource.connect())!;

    expect(await source.openSettings(), isFalse);
    expect(_sent, isNot(contains('openSettings')));
  });

  test('reports false when the command reached no host', () async {
    _installBridge(withOpenSettings: true, send: false);
    final source = (await BridgeScanSource.connect())!;

    expect(await source.openSettings(), isFalse);
  });
}
