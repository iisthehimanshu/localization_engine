import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/localization_engine.dart';
import 'package:localization_engine/location.dart';

void main() {
  // The reading shape both scanner hosts (react-native-scanner and
  // iwayplus_scanner) relay: `packetHex` is the whole advertisement in
  // uppercase hex, `""` when unavailable.
  Map<String, dynamic> reading(String name, String hex) => {
        'device': 'AA:BB:CC:DD:EE:FF',
        'name': name,
        'rssi': -70,
        'timestamp': 1700000000000,
        'manufacturerHex': 'IGNORED',
        'packetHex': hex,
      };

  test('collects 0x-prefixed packets of filtered beacons only', () {
    final batch = [
      reading('IW1', '0B09495732353033303930320EFF05056020F901F4000000000000'),
      reading('IW1', '0B09495732353033303930320EFF05056020F901F4000000000000'),
      reading('IW2', '0b09495732353033303930330eff05056120f901f4000000000000'), // normalised to upper
      reading('IW3', 'ABCD'), // not annotated
      reading('IW4', ''), // older scanner / no packet
    ];
    final filtered = {
      'IW1': [MapEntry(DateTime(2026), -70)],
      'IW2': [MapEntry(DateTime(2026), -70)],
      'IW4': [MapEntry(DateTime(2026), -70)],
    };

    expect(LocalizationEngine.visiblePackets(batch, filtered), {
      '0x0B09495732353033303930320EFF05056020F901F4000000000000',
      '0x0B09495732353033303930330EFF05056120F901F4000000000000',
    });
  });

  test('toJson stays JSON-encodable and round-trips', () {
    final loc = BeaconPointLocation(
      x: 1,
      y: 2,
      bid: 'b',
      floor: 0,
      latitude: 0,
      longitude: 0,
      beacons: const ['IW1'],
      visibleBeacons: {'0x0B09495732353033303930320EFF05056020F901F4000000000000'},
      rssi: -70,
      bestFloor: 0,
      timeStamp: DateTime(2026),
    );
    final decoded = jsonDecode(jsonEncode(loc.toJson()));
    expect(BeaconPointLocation.fromJson(decoded).visibleBeacons,
        {'0x0B09495732353033303930320EFF05056020F901F4000000000000'});
  });
}
