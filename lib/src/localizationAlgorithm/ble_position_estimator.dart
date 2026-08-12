// ble_position_estimator.dart
// Fully offline, on-device BLE indoor position estimator.
// Adapted from the reference BLEPositionEstimator to use the project's
// [Beacon] model (see src/network/model/beaconData.dart) as its beacon
// database instead of the reference `BeaconMeta` type.
//
// Usage:
//   final est = BLEPositionEstimator(beaconDb: localization.apibeaconmap);
//   final pos = est.update(readings, walking: _isNavigating);
//   if (pos != null) { x = pos.smoothX; y = pos.smoothY; }

import 'dart:math';
import 'dart:collection';

import '../network/model/beaconData.dart';

// ── One raw BLE reading ───────────────────────────────────────────────────────
class BleReading {
  final String name;
  final int rssi;
  final DateTime timestamp;
  BleReading({
    required this.name,
    required this.rssi,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Venue-specific correction for a beacon whose transmitter or mounting makes
/// its RSSI systematically different from its peers.
class BeaconSignalCalibration {
  const BeaconSignalCalibration({
    this.rssiOffset = 0,
    this.reliability = 1,
  }) : assert(reliability >= 0 && reliability <= 1);

  final double rssiOffset;
  final double reliability;
}

/// Calibrated affine conversion from floor-plan pixels to latitude/longitude.
class FloorGeoTransform {
  const FloorGeoTransform({
    required this.latitudeOrigin,
    required this.longitudeOrigin,
    required this.latitudePerPixelX,
    required this.latitudePerPixelY,
    required this.longitudePerPixelX,
    required this.longitudePerPixelY,
  });

  final double latitudeOrigin;
  final double longitudeOrigin;
  final double latitudePerPixelX;
  final double latitudePerPixelY;
  final double longitudePerPixelX;
  final double longitudePerPixelY;

  List<double> convert(double x, double y) => <double>[
        latitudeOrigin + latitudePerPixelX * x + latitudePerPixelY * y,
        longitudeOrigin + longitudePerPixelX * x + longitudePerPixelY * y,
      ];
}

/// Projects an estimate onto venue-specific walkable geometry.
typedef LocalPositionConstraint = Point<double> Function(
  String building,
  int floor,
  Point<double> estimated,
);

// ── Position result returned on every update() call ──────────────────────────
class PositionResult {
  /// EMA-smoothed local floor-plan coordinates
  final double smoothX, smoothY;

  /// Unsmoothed softmax centroid (useful for debugging)
  final double rawX, rawY;

  /// GPS estimate — null if beacon DB has no GPS coordinates
  final double? smoothLat, smoothLon;

  /// "high" | "medium" | "low"
  final String confidence;

  /// "walking" | "stationary"
  final String motionState;

  /// Building the fix was resolved in — coordinates are only meaningful
  /// relative to this building's floor-plan grid.
  final String building;

  /// Floor the fix was resolved on
  final int floor;

  /// True when this update switched to a different building, meaning the
  /// smoothing state was reset and the position teleported to a new grid.
  final bool buildingChanged;

  /// Strongest beacon this window
  final String rank1Beacon;
  final int rank1Rssi;

  /// Softmax weight of rank-1 beacon (0–1, higher = more dominant)
  final double rank1Weight;

  /// Distance the smoothed position moved since last update (pixels)
  final double jumpPx;

  /// Number of beacons detected in the current window
  final int nBeacons;

  /// True on the single update that committed a different [floor] — the
  /// coordinates now refer to a different floor plan.
  final bool floorChanged;

  /// Floor currently challenging [floor] and waiting out its dwell period, or
  /// null when the floor is settled. Non-null means a floor change is in
  /// progress: a host app can pre-warm this floor's plan, but should keep
  /// rendering against [floor] until it commits.
  final int? pendingFloor;

  /// dBm by which [floor] leads the runner-up floor. Negative while a
  /// challenger is pending — i.e. we are deliberately holding the old floor.
  /// 0 when only one floor is in view.
  final double floorMargin;

  /// "high" | "medium" | "low" — how separable [floor] is from the runner-up.
  final String floorConfidence;

  const PositionResult({
    required this.smoothX,
    required this.smoothY,
    required this.rawX,
    required this.rawY,
    this.smoothLat,
    this.smoothLon,
    required this.confidence,
    required this.motionState,
    required this.building,
    required this.floor,
    this.buildingChanged = false,
    required this.rank1Beacon,
    required this.rank1Rssi,
    required this.rank1Weight,
    required this.jumpPx,
    required this.nBeacons,
    this.floorChanged = false,
    this.pendingFloor,
    this.floorMargin = 0.0,
    this.floorConfidence = 'low',
  });

  @override
  String toString() =>
      'pos=(${smoothX.toStringAsFixed(1)}, ${smoothY.toStringAsFixed(1)}) '
      'bid=$building floor=$floor '
      'conf=$confidence motion=$motionState b1=$rank1Beacon '
      'jump=${jumpPx.toStringAsFixed(1)}px'
      '${pendingFloor != null ? ' →$pendingFloor?' : ''}'
      '${floorChanged ? ' FLOOR-SWITCH' : ''}'
      '${buildingChanged ? ' BUILDING-SWITCH' : ''}';
}

// ── Internal aggregation state ────────────────────────────────────────────────
class _Agg {
  final int lx, ly, floor;
  final String building;
  // [peak] is the true strongest reading this window — kept for display
  // (rank1Rssi) where "how strong was the best ping" is the right question.
  // [sumRssi]/[n] feed [meanRssi], which is what positioning actually scores
  // on: a single noisy/multipath spike can make [peak] lie about how close a
  // beacon really is, but it can't drag an average of several readings far.
  int peak, sumRssi, n;
  final List<int> readings;
  DateTime latestTimestamp;
  int latestRssi;
  final BeaconSignalCalibration calibration;
  double penPeak = 0, score = 0;
  _Agg({
    required this.lx,
    required this.ly,
    required this.floor,
    required this.building,
    required this.peak,
    required this.sumRssi,
    required this.n,
    required this.readings,
    required this.latestTimestamp,
    required this.latestRssi,
    required this.calibration,
  });
  double get rawMeanRssi => sumRssi / n;

  double get medianRssi {
    final sorted = readings.map((value) => value.toDouble()).toList()..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  double get mad {
    final median = medianRssi;
    final deviations = readings
        .map((value) => (value - median).abs().toDouble())
        .toList()
      ..sort();
    final middle = deviations.length ~/ 2;
    return deviations.length.isOdd
        ? deviations[middle]
        : (deviations[middle - 1] + deviations[middle]) / 2;
  }

  double get robustMeanRssi {
    final median = medianRssi;
    final radius = max(2.0, 3 * mad);
    final accepted =
        readings.where((value) => (value - median).abs() <= radius).toList();
    final values = accepted.isEmpty ? readings : accepted;
    return values.fold<double>(0, (sum, value) => sum + value) / values.length;
  }

  // Blend a robust window statistic with the freshest observation. This keeps
  // multipath spikes from dominating while allowing real movement (including
  // a floor challenger losing its lead) to affect the next decision promptly.
  double get meanRssi =>
      (robustMeanRssi * 0.65 + latestRssi * 0.35) + calibration.rssiOffset;

  double get stabilityWeight =>
      calibration.reliability.clamp(0.0, 1.0) / (1 + mad / 4);
}

class _BufEntry {
  final String name;
  final int rssi;
  final DateTime ts;
  _BufEntry(this.name, this.rssi, this.ts);
}

// ── Main estimator ────────────────────────────────────────────────────────────
class BLEPositionEstimator {
  // Beacon database: beacon name → [Beacon] metadata.
  final Map<String, Beacon> beaconDb;

  // Rolling window length in seconds
  final double windowS;

  // Softmax temperature. Lower = sharper focus on strongest beacon.
  // 3 = sharp/accurate   5 = balanced (default)   10 = very smooth
  final double temp;

  // Use top-N beacons per estimate (3–6 recommended)
  final int topN;

  // Force a specific floor. null = auto-detect from majority vote.
  final int? floor;

  // Force a specific building. null = auto-detect from the strongest beacon
  // (with hysteresis, see [_selectBuilding]).
  final String? building;

  /// Per-beacon RSSI correction and reliability learned during venue survey.
  final Map<String, BeaconSignalCalibration> beaconCalibrations;

  /// Physical scale for each floor, keyed as `buildingId:floor`.
  final Map<String, double> pixelsPerMeterByFloor;
  final Map<String, FloorGeoTransform> geoTransformsByFloor;
  final LocalPositionConstraint? positionConstraint;

  // ── Tunable constants ──────────────────────────────────────────────────────
  static const double _continuityBonus = 0.5; // dBm bonus for repeat beacons
  static const double _rssiGapThresh = 8.0; // heuristic walking signal
  static const double _posDeltaThresh = 12.0; // heuristic walking signal (px)
  static const double _alphaStationary = 0.25; // EMA α stationary
  static const double _alphaWalking = 0.7; // EMA α walking
  static const int _rssiMin = -110;
  static const int _rssiMax = -55;
  // Trust band a beacon's aggregated RSSI must sit inside to be positioned on.
  // Above the ceiling the reading is implausibly hot (stuck/reflected spike),
  // below the floor the beacon is too far away to say anything useful about
  // where we are — either way it must not reach the top-N centroid.
  static const double _beaconRssiCeil = -50.0;
  static const double _beaconRssiFloor = -95.0;
  // dBm the challenger building must beat the current one by before we switch.
  // Prevents flapping between buildings at a shared boundary.
  static const double _bldSwitchMargin = 4.0;

  // ── Floor-selection constants ──────────────────────────────────────────────
  // Failure here is asymmetric: switching floors late costs a few seconds of
  // stale floor plan, switching early costs a wrong floor plan *and* silently
  // disables the caller's GPS fallback (which is gated on floor 0). Every
  // value below is tuned on that basis.
  //
  // Ceiling the floor vote clamps a beacon's score to. Same value as
  // [_beaconRssiCeil], but applied as a clamp rather than a filter: an
  // implausibly hot reading is still honest evidence of *which* floor we're
  // near, it just must not be able to manufacture a landslide on its own.
  //
  // Note this is currently a backstop that never fires: the ingest filter
  // already drops anything at or above [_rssiMax] (-55), so no aggregated
  // score can reach -50. It is kept — like [_beaconRssiCeil], which is dead
  // for the same reason — so that loosening [_rssiMax] can't silently hand a
  // stuck or reflected beacon the power to teleport the floor.
  static const double _floorVoteCeil = -50.0;
  // dBm the challenger floor must beat the incumbent by. A concrete slab costs
  // 15–30 dB at 2.4 GHz and per-window meanRssi noise is σ≈3–4 dB, so 6 dB is
  // ~1.5–2σ — wide enough to kill flapping, far below a genuine one-floor
  // transition. Larger than [_bldSwitchMargin] because vertical bleed-through
  // between floors is much worse than leakage between buildings.
  static const double _floorSwitchMargin = 6.0;
  // A lead this large means we did not *walk* here — elevator exit, or the app
  // resumed somewhere else. Commit without waiting out the dwell.
  static const double _floorLandslideMargin = 18.0;
  // How long the challenger must lead *continuously* before we commit. At
  // windowS=2.5 this is 1.6 full buffer turnovers on the new evidence, and ~4
  // confirming updates at the usual ~1 Hz cadence.
  static const Duration _floorDwell = Duration(seconds: 4);
  // update() cadence is not guaranteed, so the wall-clock dwell alone would let
  // a burst of updates inside 200 ms satisfy a 4-second wait. Also stops a
  // commit ever resting on a single observation.
  static const int _floorDwellMinUpdates = 2;
  // You cannot walk through two slabs at once. Dwell path only — elevators
  // reach the landslide / vanished-incumbent hatches instead.
  static const int _floorMaxStep = 1;
  // Minimum spacing between commits, to stop 1→0→1 ratcheting at a ramp mouth.
  // The dwell alone doesn't give this: after a commit the reverse challenger
  // can start dwelling immediately and commit ~4s later.
  static const Duration _minCommitGap = Duration(seconds: 6);

  // ── Rolling state ──────────────────────────────────────────────────────────
  final Queue<_BufEntry> _buf = Queue();
  List<double>? _emaPos; // [x, y]
  Set<String> _prevTop2 = {};
  String? _prevR1;
  List<double>? _prevRawPos;
  String? _currBuilding;

  int? _currFloor; // committed floor (within _currBuilding)
  int? _pendFloor; // challenger awaiting its dwell, null = none
  DateTime? _pendSince; // when the challenger first took the lead
  int _pendUpdates = 0; // consecutive updates it has led for
  DateTime? _lastCommitAt; // for _minCommitGap
  DateTime? _lastUpdateAt;

  /// Building the last fix was resolved in — coordinates from previous
  /// results are only comparable while this is unchanged.
  String? get currentBuilding => _currBuilding;

  /// Floor the last fix was committed on. Null before the first fix.
  int? get currentFloor => _currFloor;

  /// Floor currently challenging [currentFloor] and waiting out its dwell,
  /// or null when the floor is settled.
  int? get pendingFloor => _pendFloor;

  BLEPositionEstimator({
    required this.beaconDb,
    // Calibrated against a real walk log (2026-07-31) replayed through this
    // exact algorithm and cross-correlated with true beacon positions.
    // windowS trades lag against directional stability: shrinking it clears
    // the stale peak-in-window faster, cutting lag, but leaves fewer samples
    // per beacon to smooth out a noisy/multipath RSSI spike, which can
    // briefly out-vote the real beacon and jog the fix backward. Scoring on
    // meanRssi (see _Agg/step 4) instead of peak absorbs most of that noise,
    // so windowS can run tighter than it could with peak-based scoring:
    //   peak-based:  6.0 -> +2.1s lag/10 backward-jumps(worst 4.5px)
    //                3.0 -> +1.1s/25 (worst 5.3px)   1.5 -> +0.1s/102 (worst 20px)
    //   mean-based:  2.5 -> +0.7s/41 (worst 4.6px) — less lag AND a smaller
    //                worst-case backward jump than the original 6.0/peak.
    this.windowS = 2.5,
    this.temp = 3.0,
    this.topN = 5,
    this.floor,
    this.building,
    this.beaconCalibrations = const <String, BeaconSignalCalibration>{},
    this.pixelsPerMeterByFloor = const <String, double>{},
    this.geoTransformsByFloor = const <String, FloorGeoTransform>{},
    this.positionConstraint,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Injectable wall clock. Defaults to [DateTime.now]; override it so the
  /// rolling-window eviction and the floor dwell timer can be driven
  /// deterministically (tests, offline log replay) instead of in real time.
  final DateTime Function() _clock;

  // ── Call this from your BLE scan callback ─────────────────────────────────
  //
  // [readings]  — list of BleReading from the latest BLE scan
  // [walking]   — true = user is navigating, false = stationary
  //               null = auto-detect from RSSI heuristic
  //
  // Returns null if the buffer has no valid readings from known beacons.
  PositionResult? update(List<BleReading> readings, {bool? walking}) {
    final now = _clock();

    // ── 1. Ingest new readings into rolling buffer ────────────────────────
    for (final r in readings) {
      if (r.rssi <= _rssiMin || r.rssi >= _rssiMax) continue;
      if (!beaconDb.containsKey(r.name)) continue;
      _buf.add(_BufEntry(r.name, r.rssi, r.timestamp));
    }

    // ── 2. Evict readings older than windowS ─────────────────────────────
    final cutoff = now.subtract(
      Duration(milliseconds: (windowS * 1000).round()),
    );
    while (_buf.isNotEmpty && _buf.first.ts.isBefore(cutoff)) {
      _buf.removeFirst();
    }
    if (_buf.isEmpty) return null;

    // ── 3. Aggregate per-beacon: peak + mean RSSI + reading count ────────
    final Map<String, _Agg> agg = {};
    for (final e in _buf) {
      final meta = beaconDb[e.name]!;
      if (agg.containsKey(e.name)) {
        agg[e.name]!.peak = max(agg[e.name]!.peak, e.rssi);
        agg[e.name]!.sumRssi += e.rssi;
        agg[e.name]!.n++;
        agg[e.name]!.readings.add(e.rssi);
        if (!e.ts.isBefore(agg[e.name]!.latestTimestamp)) {
          agg[e.name]!.latestTimestamp = e.ts;
          agg[e.name]!.latestRssi = e.rssi;
        }
      } else {
        // A beacon without a building / grid position cannot be placed on any
        // floor plan — skip it rather than dragging the centroid somewhere
        // arbitrary.
        if (meta.coordinateX == null ||
            meta.coordinateY == null ||
            meta.floor == null ||
            meta.buildingID == null) continue;
        agg[e.name] = _Agg(
          lx: meta.coordinateX!,
          ly: meta.coordinateY!,
          floor: meta.floor!,
          building: meta.buildingID!,
          peak: e.rssi,
          sumRssi: e.rssi,
          n: 1,
          readings: <int>[e.rssi],
          latestTimestamp: e.ts,
          latestRssi: e.rssi,
          calibration:
              beaconCalibrations[e.name] ?? const BeaconSignalCalibration(),
        );
      }
    }
    if (agg.isEmpty) return null;

    // ── 4. Score = mean RSSI, penalized for sparse readings ──────────────
    // A MAD-filtered mean is more resistant to reflections and one-off spikes.
    // Unstable and old observations are penalized in addition to sparse ones.
    for (final b in agg.values) {
      final sparsePenalty = b.n == 1
          ? 4.0
          : b.n == 2
              ? 2.0
              : 0.0;
      final instabilityPenalty = min(8.0, b.mad * 0.5);
      final reliabilityPenalty =
          (1 - b.calibration.reliability.clamp(0.0, 1.0)) * 10;
      final ageSeconds =
          max(0, now.difference(b.latestTimestamp).inMilliseconds) / 1000;
      final agePenalty = min(4.0, ageSeconds * 1.5);
      b.penPeak = b.meanRssi -
          sparsePenalty -
          instabilityPenalty -
          reliabilityPenalty -
          agePenalty;
    }

    // ── 5. Building selection ────────────────────────────────────────────
    // Must happen before the floor vote: floor numbers are only unique within
    // a building, and each building has its own floor-plan coordinate grid.
    // Mixing two buildings would average coordinates from unrelated grids.
    final targetBuilding = building ?? _selectBuilding(agg);
    final bldEntries =
        agg.entries.where((e) => e.value.building == targetBuilding).toList();
    if (bldEntries.isEmpty) return null;

    // Entering a different building invalidates every piece of smoothing
    // state — the old EMA position, velocity cap and continuity set all refer
    // to a coordinate grid that no longer applies.
    final buildingChanged =
        _currBuilding != null && _currBuilding != targetBuilding;
    if (buildingChanged) {
      _emaPos = null;
      _prevTop2 = {};
      _prevR1 = null;
      _prevRawPos = null;
      // Floor numbers are only meaningful inside a building: "floor 1" next
      // door has nothing to do with the floor 1 we were just on, so there is
      // no incumbent worth defending and no dwell worth finishing.
      _currFloor = null;
      _lastCommitAt = null;
      _lastUpdateAt = null;
      _clearPendingFloor();
    }
    _currBuilding = targetBuilding;

    // ── 6. Floor selection (within the chosen building) ──────────────────
    // Out-of-band beacons are dropped from *positioning* here rather than at
    // the top-N cut so a bad reading can't sneak in as rank-1 or inflate
    // nBeacons either. The building and floor votes above still see them: a
    // hot or faint beacon is untrustworthy about *where* on the grid we are,
    // but it's still evidence of *which* building/floor we're on. (The floor
    // vote additionally clamps hot readings — see [_floorEvidence].)
    final (targetFloor, floorChanged) = floor != null
        ? (floor!, false)
        : _selectFloor(bldEntries, now, buildingChanged: buildingChanged);
    // Keep the state machine coherent if a caller ever stops forcing the floor.
    if (floor != null) _currFloor = floor;

    final floorAll =
        bldEntries.where((e) => e.value.floor == targetFloor).toList();
    if (floorAll.isEmpty) return null; // only reachable with a forced floor
    var floorEntries = floorAll
        .where((e) =>
            e.value.meanRssi <= _beaconRssiCeil &&
            e.value.meanRssi >= _beaconRssiFloor)
        .toList();
    // Every beacon on the committed floor has drifted out of the trust band —
    // routine while holding a floor through a transition, when the one beacon
    // still vouching for it is fading. Holding is still the right call, but
    // returning null would throw the fix away entirely, which is worse than a
    // slightly stale one. Position on the untrusted beacons and say so.
    final bandRelaxed = floorEntries.isEmpty;
    if (bandRelaxed) floorEntries = floorAll;

    // ── 7. Continuity bonus + re-rank ────────────────────────────────────
    for (final e in floorEntries) {
      e.value.score = e.value.penPeak +
          (_prevTop2.contains(e.key) ? _continuityBonus : 0.0);
    }
    floorEntries.sort((a, b) => b.value.score.compareTo(a.value.score));

    // ── 8. Softmax weighted centroid on top-N ────────────────────────────
    final top = floorEntries.take(topN).toList();
    final rssis = top.map((e) => e.value.penPeak).toList();
    final maxR = rssis.reduce(max);
    final expW = <double>[
      for (var i = 0; i < top.length; i++)
        exp((rssis[i] - maxR) / temp) * top[i].value.stabilityWeight,
    ];
    final sumW = expW.fold(0.0, (a, b) => a + b);
    if (sumW <= 0) return null;
    final wNorm = expW.map((w) => w / sumW).toList();

    double rawX = 0, rawY = 0;
    for (int i = 0; i < top.length; i++) {
      rawX += wNorm[i] * top[i].value.lx;
      rawY += wNorm[i] * top[i].value.ly;
    }

    final currTop2 = top.take(2).map((e) => e.key).toSet();
    final currR1 = floorEntries.first.key;
    final rssiGap = floorEntries.length > 1
        ? (floorEntries[0].value.penPeak - floorEntries[1].value.penPeak).abs()
        : 0.0;

    // ── 9. Motion detection ──────────────────────────────────────────────
    final bool isWalking;
    if (walking != null) {
      // Explicit flag from app navigation state — most accurate
      isWalking = walking;
    } else if (_prevR1 == null) {
      // First window — no reference yet
      isWalking = false;
    } else {
      // Heuristic: vote from 3 independent signals (walking if ≥2 fire)
      int signals = 0;
      if (currR1 != _prevR1) signals++;
      if (_prevRawPos != null) {
        final dx = rawX - _prevRawPos![0];
        final dy = rawY - _prevRawPos![1];
        if (sqrt(dx * dx + dy * dy) >= _posDeltaThresh) signals++;
      }
      if (rssiGap >= _rssiGapThresh) signals++;
      isWalking = signals >= 2;
    }

    final alpha = isWalking ? _alphaWalking : _alphaStationary;
    final pixelsPerMeter =
        pixelsPerMeterByFloor['$targetBuilding:$targetFloor'] ?? 4.0;
    final elapsedSeconds = _lastUpdateAt == null
        ? 1.0
        : (now.difference(_lastUpdateAt!).inMilliseconds / 1000)
            .clamp(0.25, 3.0);
    final maxJump =
        (isWalking ? 6.0 : 0.75) * max(0.1, pixelsPerMeter) * elapsedSeconds;

    // ── 10. Velocity cap + EMA ───────────────────────────────────────────
    double jumpPx = 0.0;
    if (_emaPos == null) {
      _emaPos = [rawX, rawY];
    } else {
      final dx = rawX - _emaPos![0];
      final dy = rawY - _emaPos![1];
      jumpPx = sqrt(dx * dx + dy * dy);
      double cx = rawX, cy = rawY;
      if (jumpPx > maxJump) {
        final scale = maxJump / jumpPx;
        cx = _emaPos![0] + dx * scale;
        cy = _emaPos![1] + dy * scale;
      }
      _emaPos = [
        alpha * cx + (1 - alpha) * _emaPos![0],
        alpha * cy + (1 - alpha) * _emaPos![1],
      ];
    }

    if (positionConstraint != null) {
      final constrained = positionConstraint!(
        targetBuilding,
        targetFloor,
        Point<double>(_emaPos![0], _emaPos![1]),
      );
      if (constrained.x.isFinite && constrained.y.isFinite) {
        _emaPos = <double>[constrained.x, constrained.y];
      }
    }

    final sx = _emaPos![0], sy = _emaPos![1];

    // ── 11. GPS estimate (anchors from this building only) ───────────────
    final gps = _localToGps(sx, sy, targetBuilding, targetFloor);

    // Update rolling state
    _prevTop2 = currTop2;
    _prevR1 = currR1;
    _prevRawPos = [rawX, rawY];
    _lastUpdateAt = now;

    final topW = wNorm.isNotEmpty ? wNorm[0] : 0.0;

    // How separable the committed floor is from its nearest rival. Negative
    // while we're holding a floor against a stronger challenger, which is
    // exactly the signal a host app wants in order to distrust the floor.
    final evidence = _floorEvidence(bldEntries);
    double? runnerUp;
    evidence.forEach((f, v) {
      if (f == targetFloor) return;
      if (runnerUp == null || v > runnerUp!) runnerUp = v;
    });
    final floorMargin = runnerUp == null
        ? 0.0 // only one floor in view
        : (evidence[targetFloor] ?? runnerUp!) - runnerUp!;
    // A single floor in view is unambiguous, not marginal — don't let its 0.0
    // margin read as the low-confidence "two floors are tied" case.
    final floorConf = runnerUp == null ? 'high' : _floorConf(floorMargin);

    return PositionResult(
      smoothX: sx,
      smoothY: sy,
      rawX: rawX,
      rawY: rawY,
      smoothLat: gps?[0],
      smoothLon: gps?[1],
      // Nothing on this floor is inside the trust band — we're positioning on
      // readings we'd normally reject, so don't dress it up as a good fix.
      confidence: bandRelaxed
          ? 'low'
          : _confidence(top.length, floorEntries.first.value.penPeak, topW),
      motionState: isWalking ? 'walking' : 'stationary',
      building: targetBuilding,
      floor: targetFloor,
      buildingChanged: buildingChanged,
      rank1Beacon: floorEntries.first.key,
      rank1Rssi: floorEntries.first.value.peak,
      rank1Weight: topW,
      jumpPx: jumpPx,
      nBeacons: floorEntries.length,
      floorChanged: floorChanged,
      pendingFloor: _pendFloor,
      floorMargin: floorMargin,
      floorConfidence: floorConf,
    );
  }

  // ── Reset all state (call when starting a new session) ─────────────────
  void reset() {
    _buf.clear();
    _emaPos = null;
    _prevTop2 = {};
    _prevR1 = null;
    _prevRawPos = null;
    _currBuilding = null;
    _currFloor = null;
    _lastCommitAt = null;
    _lastUpdateAt = null;
    _clearPendingFloor();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Picks the building the user is most likely inside.
  ///
  /// Scored on the strongest (penalty-adjusted) beacon per building rather
  /// than beacon count — a handful of loud nearby beacons beats a crowd of
  /// faint ones bleeding through from the building next door. The incumbent
  /// building is kept unless a challenger beats it by [_bldSwitchMargin] dBm,
  /// so we don't flap back and forth at a shared boundary.
  String _selectBuilding(Map<String, _Agg> agg) {
    final best = <String, double>{};
    for (final v in agg.values) {
      final b = best[v.building];
      if (b == null || v.penPeak > b) best[v.building] = v.penPeak;
    }

    final leader = best.entries.reduce((a, b) => a.value >= b.value ? a : b);

    final curr = _currBuilding;
    if (curr == null || !best.containsKey(curr)) {
      // No incumbent, or it has dropped out of the window entirely.
      return leader.key;
    }
    return leader.value > best[curr]! + _bldSwitchMargin ? leader.key : curr;
  }

  /// Strongest (penalty-adjusted, ceiling-clamped) beacon per floor.
  ///
  /// Scored on the single best beacon rather than beacon count, because a
  /// floor's beacon count reflects how densely the venue happened to be
  /// surveyed, not where the user is standing. One beacon at -60 dBm directly
  /// overhead is far stronger evidence than five at -88 bleeding up an open
  /// ramp — which is exactly the case a count vote gets backwards. Same shape
  /// as [_selectBuilding], and it keeps every threshold in real dBm so they
  /// can be reasoned about from slab attenuation and tuned by measurement.
  ///
  /// Scoring on the max is only safe because [penPeak] is already a windowed
  /// mean with a sparse-reading penalty (see step 4), so a single loud ping
  /// can't reach this vote undamped.
  Map<int, double> _floorEvidence(List<MapEntry<String, _Agg>> entries) {
    final best = <int, double>{};
    for (final e in entries) {
      // Clamp rather than drop: see [_floorVoteCeil].
      final v = min(e.value.penPeak, _floorVoteCeil);
      final b = best[e.value.floor];
      if (b == null || v > b) best[e.value.floor] = v;
    }
    return best;
  }

  /// Picks the floor the user is standing on, within the already-chosen
  /// building. Three defences stack:
  ///   1. evidence (strongest beacon) rather than beacon count
  ///   2. [_floorSwitchMargin] hysteresis in favour of the incumbent
  ///   3. [_floorDwell] of *continuous* leadership before committing
  ///
  /// (3) is what stops the floor flipping the instant a crowd of beacons from
  /// the floor below comes into view — on a ramp they arrive long before the
  /// user does. The challenger must hold its lead on every update; one window
  /// where it slips inside the margin restarts the clock.
  ///
  /// Returns (floor, changed).
  (int, bool) _selectFloor(
    List<MapEntry<String, _Agg>> entries,
    DateTime now, {
    required bool buildingChanged,
  }) {
    final best = _floorEvidence(entries);
    final leader = best.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final curr = _currFloor;

    // Nothing to defend: cold start, a building change (floor numbers aren't
    // comparable across buildings), or the incumbent floor has dropped out of
    // the window entirely — mirrors _selectBuilding's !best.containsKey(curr).
    if (curr == null || buildingChanged || !best.containsKey(curr)) {
      return _commitFloor(leader.key, now);
    }

    final lead = leader.value - best[curr]!;

    // Incumbent still leads, or the challenger is inside the deadband. Drop
    // any pending challenge — the dwell has to be continuous to mean anything.
    if (leader.key == curr || lead <= _floorSwitchMargin) {
      _clearPendingFloor();
      return (curr, false);
    }

    // Landslide: the incumbent's own best beacon is a full slab weaker than
    // the challenger's. We didn't walk here, so there's nothing to wait for,
    // and waiting would strand us on a floor we can prove we're not on.
    if (lead >= _floorLandslideMargin) return _commitFloor(leader.key, now);

    // ── Plausibility gates (dwell path only) ──────────────────────────────
    // Can't cross two slabs at once on foot; a genuine multi-floor move is an
    // elevator, which lands on the landslide or vanished-incumbent hatch above.
    if ((leader.key - curr).abs() > _floorMaxStep) {
      _clearPendingFloor();
      return (curr, false);
    }
    if (_lastCommitAt != null &&
        now.difference(_lastCommitAt!) < _minCommitGap) {
      return (curr, false);
    }

    // ── Dwell ─────────────────────────────────────────────────────────────
    if (_pendFloor != leader.key) {
      _pendFloor = leader.key;
      _pendSince = now;
      _pendUpdates = 1;
      return (curr, false);
    }
    _pendUpdates++;
    if (now.difference(_pendSince!) >= _floorDwell &&
        _pendUpdates >= _floorDwellMinUpdates) {
      return _commitFloor(leader.key, now);
    }
    return (curr, false); // challenger convincing but not yet sustained
  }

  (int, bool) _commitFloor(int f, DateTime now) {
    final changed = _currFloor != null && _currFloor != f;
    _currFloor = f;
    _lastCommitAt = now;
    _clearPendingFloor();
    return (f, changed);
  }

  void _clearPendingFloor() {
    _pendFloor = null;
    _pendSince = null;
    _pendUpdates = 0;
  }

  List<double>? _localToGps(
    double lx,
    double ly,
    String building,
    int floor,
  ) {
    final transform = geoTransformsByFloor['$building:$floor'];
    if (transform != null) return transform.convert(lx, ly);

    double tw = 0, la = 0, lo = 0;
    for (final m in beaconDb.values) {
      // Anchors from another building sit on a different pixel grid, so their
      // distance to (lx, ly) is meaningless.
      if (m.buildingID != building || m.floor != floor) continue;
      final lat = double.tryParse(m.properties?.latitude ?? '');
      final lon = double.tryParse(m.properties?.longitude ?? '');
      if (lat == null || lon == null) continue;
      if (m.coordinateX == null || m.coordinateY == null) continue;
      final dx = lx - m.coordinateX!, dy = ly - m.coordinateY!;
      final d = max(sqrt(dx * dx + dy * dy), 0.5);
      final w = 1.0 / (d * d);
      la += w * lat;
      lo += w * lon;
      tw += w;
    }
    if (tw == 0) return null;
    return [la / tw, lo / tw];
  }

  /// Buckets [PositionResult.floorMargin] into a label. "medium" starts at the
  /// switch margin because that is, by construction, the point at which the
  /// algorithm itself considers two floors distinguishable.
  static String _floorConf(double m) => m >= 12.0
      ? 'high'
      : m >= _floorSwitchMargin
          ? 'medium'
          : 'low';

  String _confidence(int n, double bestRssi, double topW) {
    int s = 0;
    if (topW > 0.55)
      s += 3;
    else if (topW > 0.35)
      s += 2;
    else
      s += 1;
    if (n >= 5)
      s += 2;
    else if (n >= 3) s += 1;
    if (bestRssi >= -75)
      s += 2;
    else if (bestRssi >= -85) s += 1;
    return s >= 6
        ? 'high'
        : s >= 4
            ? 'medium'
            : 'low';
  }
}
