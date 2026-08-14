import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine_example/main.dart';

void main() {
  testWidgets('shows localization host controls', (tester) async {
    await tester.pumpWidget(const LocalizationHostApp());

    expect(find.text('Localization host'), findsWidgets);
    expect(find.text('Venue name'), findsOneWidget);
    expect(find.text('GPS'), findsOneWidget);
    expect(find.text('BLE'), findsOneWidget);
    expect(find.text('Both'), findsOneWidget);
    expect(
      find.text('Surrounding-device scan interval (seconds)'),
      findsOneWidget,
    );
  });
}
