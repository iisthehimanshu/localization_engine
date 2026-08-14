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

  test('nearby devices are included in the existing tracking payload', () {
    final payload = TrackingPayload(
      id: 'scanner-a',
      t: 1234,
      pts: const <String, List<int?>>{},
      venueName: 'Iwayplus',
      surroundingDevices: const <String, int>{'device-a': -63},
    );

    expect(payload.toJson(), <String, dynamic>{
      'id': 'scanner-a',
      't': 1234,
      'pts': <String, List<int?>>{},
      'devices': <String, int>{'device-a': -63},
      'buildingId': 'Iwayplus',
    });
  });

  test('tracking payload omits devices before an interval completes', () {
    final payload = TrackingPayload(
      id: 'scanner-a',
      t: 1234,
      pts: const <String, List<int?>>{},
      venueName: 'Iwayplus',
    );
    expect(payload.toJson(), isNot(contains('devices')));
  });
}
