import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/src/network/api/UserTrackingWebSocket.dart';
import 'package:localization_engine/src/surrounding_device_rssi_aggregator.dart';

void main() {
  test('aggregates one median RSSI per BLE device and clears the window', () {
    final aggregator = SurroundingDeviceRssiAggregator();
    for (final rssi in <int>[-80, -60, -70]) {
      aggregator.add(<String, dynamic>{'device': 'device-a', 'rssi': rssi});
    }
    aggregator.add(<String, dynamic>{'device': 'device-b', 'rssi': -55});
    aggregator.add(<String, dynamic>{'device': '', 'rssi': -50});

    expect(
      aggregator.takeMedianSnapshot(),
      <String, int>{'device-a': -70, 'device-b': -55},
    );
    expect(aggregator.takeMedianSnapshot(), isEmpty);
  });

  test('nearby-device payload is separate from tracking payload', () {
    const payload = SurroundingDevicesPayload(
      scannerId: 'scanner-a',
      timestamp: 1234,
      devices: <String, int>{'device-a': -63},
      venueName: 'Iwayplus',
    );

    expect(payload.toJson(), <String, dynamic>{
      'scannerId': 'scanner-a',
      'timestamp': 1234,
      'devices': <String, int>{'device-a': -63},
      'buildingId': 'Iwayplus',
    });
  });
}
