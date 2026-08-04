// Floor-selection behaviour of [BLEPositionEstimator].
//
// The case these exist for: walking down a ramp from floor 1 to floor 0, where
// floor 1 has a single beacon at the ramp head and floor 0 has several. The
// floor-0 beacons come into view long before the user arrives, and a
// count-based vote flips the floor immediately. Floor must hold until the
// evidence is both stronger *and* sustained.
//
// The estimator is pure Dart, so these need no Flutter binding — but the
// package's only test dependency is flutter_test, so run with `flutter test`.

import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/src/localizationAlgorithm/ble_position_estimator.dart';
import 'package:localization_engine/src/network/model/beaconData.dart';

/// Fake wall clock the whole suite drives by hand — see the estimator's
/// injectable `clock` parameter.
late DateTime t;

Beacon _b(String name, int x, int y, int floor, {String bld = 'B1'}) => Beacon(
      name: name,
      coordinateX: x,
      coordinateY: y,
      floor: floor,
      buildingID: bld,
    );

BLEPositionEstimator _est(Map<String, Beacon> db) =>
    BLEPositionEstimator(beaconDb: db, clock: () => t);

/// Advances the clock and feeds one reading per named beacon.
///
/// NB the estimator's rolling window is 2.5s, so a beacon dropped from
/// [rssiByName] lingers in the buffer for ~2.5s before it stops counting.
PositionResult? _tick(
  BLEPositionEstimator e,
  Map<String, int> rssiByName, {
  Duration step = const Duration(seconds: 1),
}) {
  t = t.add(step);
  return e.update(
    [
      for (final r in rssiByName.entries)
        BleReading(name: r.key, rssi: r.value, timestamp: t),
    ],
    walking: true,
  );
}

void main() {
  // A ramp landing: one beacon on floor 1, five on floor 0 below it.
  final rampDb = <String, Beacon>{
    'f1a': _b('f1a', 100, 100, 1),
    'f0a': _b('f0a', 200, 200, 0),
    'f0b': _b('f0b', 210, 200, 0),
    'f0c': _b('f0c', 220, 200, 0),
    'f0d': _b('f0d', 230, 200, 0),
    'f0e': _b('f0e', 240, 200, 0),
  };
  const floor0Far = {
    'f0a': -88,
    'f0b': -88,
    'f0c': -88,
    'f0d': -88,
    'f0e': -88,
  };
  const floor0Near = {
    'f0a': -74,
    'f0b': -74,
    'f0c': -74,
    'f0d': -74,
    'f0e': -74,
  };

  setUp(() => t = DateTime(2026, 1, 1, 12, 0, 0));

  group('evidence beats count', () {
    test('one strong floor-1 beacon holds against five faint floor-0 beacons',
        () {
      final e = _est(rampDb);
      for (var i = 0; i < 10; i++) {
        final pos = _tick(e, {'f1a': -60, ...floor0Far});
        expect(pos, isNotNull);
        expect(pos!.floor, 1,
            reason: 'tick $i: five faint beacons out-voted one strong one');
        expect(pos.pendingFloor, isNull,
            reason: 'tick $i: floor 0 is 24dB behind — it should not even '
                'register as a challenger');
      }
    });

    test('floor 0 wins once its beacons are genuinely the strongest', () {
      final e = _est(rampDb);
      _tick(e, {'f1a': -60, ...floor0Far});

      DateTime? firstPending;
      DateTime? committed;
      for (var i = 0; i < 25 && committed == null; i++) {
        final pos = _tick(e, {'f1a': -86, ...floor0Near});
        if (pos!.pendingFloor == 0) firstPending ??= t;
        if (pos.floorChanged) committed = t;
      }

      expect(committed, isNotNull, reason: 'never committed to floor 0');
      expect(e.currentFloor, 0);
      expect(firstPending, isNotNull,
          reason: 'should have reported a pending floor before committing');
      // The whole point: the switch is deliberate, not instantaneous.
      expect(committed!.difference(firstPending!).inMilliseconds,
          greaterThanOrEqualTo(4000),
          reason: 'committed before the 4s dwell elapsed');
    });
  });

  group('hysteresis', () {
    test('a challenger inside the margin never even starts a dwell', () {
      final e = _est(rampDb);
      _tick(e, {'f1a': -80, ...floor0Far});
      // floor 0 leads by only ~3dB — inside _floorSwitchMargin (6dB).
      for (var i = 0; i < 15; i++) {
        final pos = _tick(e, {'f1a': -80, 'f0a': -77, 'f0b': -77});
        expect(pos!.floor, 1);
        expect(pos.pendingFloor, isNull);
      }
    });

    test('dwell must be continuous — an interruption restarts the clock', () {
      final e = _est(rampDb);
      _tick(e, {'f1a': -60, ...floor0Far});

      // Let the min-commit-gap since the cold-start commit expire first.
      for (var i = 0; i < 7; i++) {
        _tick(e, {'f1a': -60, ...floor0Far});
      }

      // Floor 0 takes a convincing lead for 3s — not yet enough.
      for (var i = 0; i < 3; i++) {
        final pos = _tick(e, {'f1a': -86, ...floor0Near});
        expect(pos!.floorChanged, isFalse);
      }
      // ...then floor 1 surges back for long enough to flush the window.
      for (var i = 0; i < 3; i++) {
        final pos = _tick(e, {'f1a': -60, ...floor0Far});
        expect(pos!.floor, 1);
        expect(pos.pendingFloor, isNull,
            reason: 'the interrupted challenge should have been dropped');
      }
      // Floor 0 leads again: the dwell restarts from scratch.
      final restart = t;
      DateTime? committed;
      for (var i = 0; i < 25 && committed == null; i++) {
        final pos = _tick(e, {'f1a': -86, ...floor0Near});
        if (pos!.floorChanged) committed = t;
      }
      expect(committed, isNotNull);
      expect(committed!.difference(restart).inMilliseconds,
          greaterThanOrEqualTo(4000),
          reason: 'the earlier partial dwell was wrongly counted');
    });
  });

  group('escape hatches', () {
    test('a landslide commits immediately, without the dwell', () {
      final e = _est(rampDb);
      // Establish floor 1 alone — seeding f0a weak here would leave a stale
      // sample in the 2.5s window and drag its mean below the threshold.
      _tick(e, {'f1a': -85});
      // 27dB is more than a floor slab can explain — we did not walk here.
      final pos = _tick(e, {'f1a': -85, 'f0a': -56});
      expect(pos!.floor, 0);
      expect(pos.floorChanged, isTrue);
    });

    test('a vanished incumbent floor commits immediately', () {
      final e = _est(rampDb);
      _tick(e, {'f1a': -60, ...floor0Far});
      expect(e.currentFloor, 1);

      // Floor 1 stops being reported. Step past the 2.5s window so it also
      // leaves the buffer, then it is no longer an incumbent worth defending.
      final pos = _tick(e, floor0Far, step: const Duration(seconds: 3));
      expect(pos!.floor, 0);
      expect(pos.floorChanged, isTrue);
    });

    test('a two-floor jump is rejected while the incumbent is still in view',
        () {
      final db = <String, Beacon>{
        'f1a': _b('f1a', 100, 100, 1),
        'f5a': _b('f5a', 100, 100, 5),
        'f5b': _b('f5b', 110, 100, 5),
      };
      final e = _est(db);
      _tick(e, {'f1a': -80, 'f5a': -90});
      // Floor 5 leads by 8dB: past the margin, short of a landslide. You
      // cannot walk through four slabs.
      for (var i = 0; i < 15; i++) {
        final pos = _tick(e, {'f1a': -80, 'f5a': -72, 'f5b': -72});
        expect(pos!.floor, 1);
        expect(pos.pendingFloor, isNull);
      }
      // But once floor 1 drops out entirely, there is nothing to defend.
      final pos = _tick(e, {'f5a': -72, 'f5b': -72},
          step: const Duration(seconds: 3));
      expect(pos!.floor, 5);
    });
  });

  group('state lifecycle', () {
    test('changing building clears the floor state', () {
      final db = <String, Beacon>{
        'a3': _b('a3', 10, 10, 3, bld: 'A'),
        'b3': _b('b3', 10, 10, 3, bld: 'B'),
        'b7': _b('b7', 20, 20, 7, bld: 'B'),
      };
      final e = _est(db);
      _tick(e, {'a3': -70});
      expect(e.currentFloor, 3);

      // Move to building B, where only floor 7 is visible. Floor 3 in B has
      // nothing to do with floor 3 in A, so there is no dwell to wait out.
      final pos = _tick(e, {'b7': -70}, step: const Duration(seconds: 3));
      expect(pos!.building, 'B');
      expect(pos.floor, 7);
    });

    test('reset() clears the incumbent floor', () {
      final e = _est(rampDb);
      _tick(e, {'f1a': -60, ...floor0Far});
      expect(e.currentFloor, 1);

      e.reset();
      expect(e.currentFloor, isNull);
      expect(e.pendingFloor, isNull);

      // With no incumbent, the leader commits at once.
      final pos = _tick(e, floor0Far);
      expect(pos!.floor, 0);
    });
  });

  group('holding a floor never costs the fix', () {
    test('positions on out-of-band beacons rather than returning null', () {
      final db = <String, Beacon>{'f1a': _b('f1a', 100, 100, 1)};
      final e = _est(db);
      // -97 is inside the ingest range but below the -95 trust floor, so the
      // band filter would empty the candidate list. Returning null here would
      // drop the fix entirely, which is worse than a slightly stale one.
      final pos = _tick(e, {'f1a': -97});
      expect(pos, isNotNull);
      expect(pos!.floor, 1);
      expect(pos.confidence, 'low', reason: 'a relaxed-band fix must say so');
    });
  });

  group('reported floor metadata', () {
    test('a lone floor in view is high confidence, not a tie', () {
      final db = <String, Beacon>{'f1a': _b('f1a', 100, 100, 1)};
      final pos = _tick(_est(db), {'f1a': -70});
      expect(pos!.floorMargin, 0.0);
      expect(pos.floorConfidence, 'high');
    });

    test('floorMargin goes negative while holding against a challenger', () {
      final e = _est(rampDb);
      _tick(e, {'f1a': -60, ...floor0Far});
      for (var i = 0; i < 7; i++) {
        _tick(e, {'f1a': -60, ...floor0Far});
      }
      var sawNegative = false;
      for (var i = 0; i < 3; i++) {
        final pos = _tick(e, {'f1a': -86, ...floor0Near});
        if (pos!.floor == 1 && pos.floorMargin < 0) sawNegative = true;
      }
      expect(sawNegative, isTrue,
          reason: 'holding a floor against a stronger rival should surface as '
              'a negative margin');
    });
  });
}
