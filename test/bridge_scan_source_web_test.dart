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

void main() {
  tearDown(() {
    globalContext.delete('__iwayplusScanner'.toJS);
    globalContext.delete('__sent'.toJS);
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
