import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine_example/main.dart';

void main() {
  testWidgets('shows start and stop controls', (tester) async {
    await tester.pumpWidget(const ScanLoggerApp());

    expect(find.text('Start scanning'), findsOneWidget);
    expect(find.text('Stop scanning'), findsOneWidget);
    expect(find.text('BLE advertisements'), findsOneWidget);
    expect(find.text('GPS fixes'), findsOneWidget);
    expect(find.text('Wi-Fi access point readings'), findsOneWidget);

    // Nothing to stop before a session has started.
    final stop = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Stop scanning'),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    expect(stop.onPressed, isNull);
  });
}
