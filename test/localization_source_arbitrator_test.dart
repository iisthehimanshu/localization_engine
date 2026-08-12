import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/location.dart';
import 'package:localization_engine/src/localization_mode.dart';
import 'package:localization_engine/src/localization_source_arbitrator.dart';

BeaconPointLocation _ble({required int floor, required String confidence}) =>
    BeaconPointLocation(
      x: 10,
      y: 20,
      bid: 'B1',
      floor: floor,
      latitude: 28.5,
      longitude: 77.1,
      beacons: const <String>['IW1'],
      rssi: -70,
      bestFloor: floor,
      timeStamp: DateTime.now(),
      confidence: confidence,
    );

GPSLocation _gps(String confidence) => GPSLocation(
      latitude: 28.5,
      longitude: 77.1,
      accuracy: confidence == 'high' ? 7 : 35,
      confidence: confidence,
    );

void main() {
  test('strong upper-floor BLE suppresses GPS', () {
    final decision = LocalizationSourceArbitrator.decide(
      mode: LocalizationMode.bothGPSandBLE,
      beacon: _ble(floor: 2, confidence: 'high'),
      gps: _gps('high'),
    );

    expect(decision.primarySource, 'ble');
    expect(decision.gpsLocation, isNull);
  });

  test('high-confidence GPS survives a weak upper-floor BLE observation', () {
    final decision = LocalizationSourceArbitrator.decide(
      mode: LocalizationMode.bothGPSandBLE,
      beacon: _ble(floor: 2, confidence: 'low'),
      gps: _gps('high'),
    );

    expect(decision.primarySource, 'gps');
    expect(decision.gpsLocation, isNotNull);
    expect(decision.beaconLocation, isNotNull);
  });

  test('mode is always authoritative', () {
    final decision = LocalizationSourceArbitrator.decide(
      mode: LocalizationMode.onlyGps,
      beacon: _ble(floor: 1, confidence: 'high'),
      gps: _gps('medium'),
    );

    expect(decision.beaconLocation, isNull);
    expect(decision.primarySource, 'gps');
  });
}
