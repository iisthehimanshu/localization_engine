import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/src/localizationAlgorithm/ble_position_estimator.dart';
import 'package:localization_engine/src/network/model/beaconData.dart';

Beacon _beacon(String name, int x) => Beacon(
      name: name,
      coordinateX: x,
      coordinateY: 0,
      floor: 0,
      buildingID: 'B1',
    );

void main() {
  test('a reflected RSSI spike does not overpower a stable beacon', () {
    final now = DateTime(2026, 1, 1);
    final estimator = BLEPositionEstimator(
      beaconDb: <String, Beacon>{
        'stable': _beacon('stable', 0),
        'noisy': _beacon('noisy', 100),
      },
      clock: () => now,
    );

    final result = estimator.update(<BleReading>[
      for (final rssi in <int>[-69, -70, -71, -70])
        BleReading(name: 'stable', rssi: rssi, timestamp: now),
      for (final rssi in <int>[-95, -94, -96, -56])
        BleReading(name: 'noisy', rssi: rssi, timestamp: now),
    ]);

    expect(result, isNotNull);
    expect(result!.rank1Beacon, 'stable');
    expect(result.rawX, lessThan(20));
  });

  test('per-beacon calibration corrects systematic transmitter bias', () {
    final now = DateTime(2026, 1, 1);
    final estimator = BLEPositionEstimator(
      beaconDb: <String, Beacon>{
        'uncalibrated': _beacon('uncalibrated', 0),
        'calibrated': _beacon('calibrated', 100),
      },
      beaconCalibrations: const <String, BeaconSignalCalibration>{
        'calibrated': BeaconSignalCalibration(rssiOffset: 15),
      },
      clock: () => now,
    );

    final result = estimator.update(<BleReading>[
      for (var i = 0; i < 3; i++)
        BleReading(name: 'uncalibrated', rssi: -68, timestamp: now),
      for (var i = 0; i < 3; i++)
        BleReading(name: 'calibrated', rssi: -78, timestamp: now),
    ]);

    expect(result!.rank1Beacon, 'calibrated');
    expect(result.rawX, greaterThan(50));
  });

  test('stationary input uses the stationary smoothing profile', () {
    final now = DateTime(2026, 1, 1);
    final estimator = BLEPositionEstimator(
      beaconDb: <String, Beacon>{'stable': _beacon('stable', 0)},
      clock: () => now,
    );

    final result = estimator.update(<BleReading>[
      BleReading(name: 'stable', rssi: -70, timestamp: now),
    ]);

    expect(result!.motionState, 'stationary');
  });

  test('isolated reflected position changes do not unlock walking', () {
    var now = DateTime(2026, 1, 1);
    final estimator = BLEPositionEstimator(
      beaconDb: <String, Beacon>{
        'left': _beacon('left', 0),
        'right': _beacon('right', 40),
      },
      clock: () => now,
    );

    PositionResult update(String beacon) {
      final result = estimator.update(<BleReading>[
        BleReading(name: beacon, rssi: -70, timestamp: now),
      ]);
      now = now.add(const Duration(seconds: 3));
      return result!;
    }

    expect(update('left').motionState, 'stationary');
    final reflectedAway = update('right');
    final reflectedBack = update('left');
    final settled = update('left');

    expect(reflectedAway.motionState, 'stationary');
    expect(reflectedBack.motionState, 'stationary');
    expect(settled.motionState, 'stationary');
    expect(reflectedAway.rawJumpPx, greaterThan(reflectedAway.jumpPx));
    expect(reflectedAway.jumpPx / 4, lessThanOrEqualTo(0.75 * 3 * 0.25));
  });

  test('walking requires three directionally consistent evidence windows', () {
    var now = DateTime(2026, 1, 1);
    final estimator = BLEPositionEstimator(
      beaconDb: <String, Beacon>{
        for (final x in <int>[0, 20, 40, 60]) 'b$x': _beacon('b$x', x),
      },
      clock: () => now,
    );

    PositionResult update(int x) {
      final result = estimator.update(<BleReading>[
        BleReading(name: 'b$x', rssi: -70, timestamp: now),
      ]);
      now = now.add(const Duration(seconds: 3));
      return result!;
    }

    expect(update(0).motionState, 'stationary');
    expect(update(20).motionState, 'stationary');
    expect(update(40).motionState, 'stationary');
    expect(update(60).motionState, 'walking');
    expect(update(40).motionState, 'walking');
    expect(update(60).motionState, 'stationary');
  });

  test('walkable constraint and floor transform are applied to the fix', () {
    final now = DateTime(2026, 1, 1);
    final estimator = BLEPositionEstimator(
      beaconDb: <String, Beacon>{'stable': _beacon('stable', 0)},
      geoTransformsByFloor: const <String, FloorGeoTransform>{
        'B1:0': FloorGeoTransform(
          latitudeOrigin: 28,
          longitudeOrigin: 77,
          latitudePerPixelX: 0.001,
          latitudePerPixelY: 0,
          longitudePerPixelX: 0,
          longitudePerPixelY: 0.001,
        ),
      },
      positionConstraint: (_, __, ___) => const Point<double>(10, 20),
      clock: () => now,
    );

    final result = estimator.update(<BleReading>[
      BleReading(name: 'stable', rssi: -70, timestamp: now),
    ]);

    expect(result!.smoothX, 10);
    expect(result.smoothY, 20);
    expect(result.smoothLat, closeTo(28.01, 0.000001));
    expect(result.smoothLon, closeTo(77.02, 0.000001));
  });
}
