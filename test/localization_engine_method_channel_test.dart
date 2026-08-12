import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/localization_engine.dart';

void main() {
  test('localization defaults include the combined GPS and BLE mode', () {
    expect(
      LocalizationMode.values,
      contains(LocalizationMode.bothGPSandBLE),
    );
  });
}
