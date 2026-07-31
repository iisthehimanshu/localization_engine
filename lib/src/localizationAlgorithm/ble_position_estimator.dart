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
  final String   name;
  final int      rssi;
  final DateTime timestamp;
  BleReading({
    required this.name,
    required this.rssi,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

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
  final int    rank1Rssi;
  /// Softmax weight of rank-1 beacon (0–1, higher = more dominant)
  final double rank1Weight;
  /// Distance the smoothed position moved since last update (pixels)
  final double jumpPx;
  /// Number of beacons detected in the current window
  final int    nBeacons;

  const PositionResult({
    required this.smoothX,     required this.smoothY,
    required this.rawX,        required this.rawY,
    this.smoothLat,            this.smoothLon,
    required this.confidence,  required this.motionState,
    required this.building,    required this.floor,
    this.buildingChanged = false,
    required this.rank1Beacon, required this.rank1Rssi,
    required this.rank1Weight, required this.jumpPx,
    required this.nBeacons,
  });

  @override
  String toString() =>
    'pos=(${smoothX.toStringAsFixed(1)}, ${smoothY.toStringAsFixed(1)}) '
    'bid=$building floor=$floor '
    'conf=$confidence motion=$motionState b1=$rank1Beacon '
    'jump=${jumpPx.toStringAsFixed(1)}px'
    '${buildingChanged ? ' BUILDING-SWITCH' : ''}';
}

// ── Internal aggregation state ────────────────────────────────────────────────
class _Agg {
  final int    lx, ly, floor;
  final String building;
  int peak, n;
  double penPeak = 0, score = 0;
  _Agg({
    required this.lx, required this.ly, required this.floor,
    required this.building,
    required this.peak, required this.n,
  });
}

class _BufEntry {
  final String   name;
  final int      rssi;
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

  // ── Tunable constants ──────────────────────────────────────────────────────
  static const double _continuityBonus  = 0.5;   // dBm bonus for repeat beacons
  static const double _rssiGapThresh    = 8.0;   // heuristic walking signal
  static const double _posDeltaThresh   = 12.0;  // heuristic walking signal (px)
  static const double _alphaStationary  = 0.25;  // EMA α stationary
  static const double _alphaWalking     = 0.55;  // EMA α walking
  static const double _maxJumpStat      = 3.0;   // max px/update stationary ~0.75m
  static const double _maxJumpWalk      = 30.0;  // max px/update walking    ~7.5m
  static const int    _rssiMin          = -110;
  static const int    _rssiMax          = -55;
  // dBm the challenger building must beat the current one by before we switch.
  // Prevents flapping between buildings at a shared boundary.
  static const double _bldSwitchMargin  = 4.0;

  // ── Rolling state ──────────────────────────────────────────────────────────
  final Queue<_BufEntry> _buf = Queue();
  List<double>? _emaPos;           // [x, y]
  Set<String>   _prevTop2 = {};
  String?       _prevR1;
  List<double>? _prevRawPos;
  String?       _currBuilding;

  /// Building the last fix was resolved in — coordinates from previous
  /// results are only comparable while this is unchanged.
  String? get currentBuilding => _currBuilding;

  BLEPositionEstimator({
    required this.beaconDb,
    this.windowS = 6.0,
    this.temp    = 5.0,
    this.topN    = 5,
    this.floor,
    this.building,
  });

  // ── Call this from your BLE scan callback ─────────────────────────────────
  //
  // [readings]  — list of BleReading from the latest BLE scan
  // [walking]   — true = user is navigating, false = stationary
  //               null = auto-detect from RSSI heuristic
  //
  // Returns null if the buffer has no valid readings from known beacons.
  PositionResult? update(List<BleReading> readings, {bool? walking}) {
    final now = DateTime.now();

    // ── 1. Ingest new readings into rolling buffer ────────────────────────
    for (final r in readings) {
      if (r.rssi <= _rssiMin || r.rssi >= _rssiMax) continue;
      if (!beaconDb.containsKey(r.name))            continue;
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

    // ── 3. Aggregate per-beacon: peak RSSI + reading count ───────────────
    final Map<String, _Agg> agg = {};
    for (final e in _buf) {
      final meta = beaconDb[e.name]!;
      if (agg.containsKey(e.name)) {
        agg[e.name]!.peak = max(agg[e.name]!.peak, e.rssi);
        agg[e.name]!.n++;
      } else {
        // A beacon without a building / grid position cannot be placed on any
        // floor plan — skip it rather than dragging the centroid somewhere
        // arbitrary.
        if (meta.coordinateX == null ||
            meta.coordinateY == null ||
            meta.floor      == null ||
            meta.buildingID == null) continue;
        agg[e.name] = _Agg(
          lx: meta.coordinateX!, ly: meta.coordinateY!, floor: meta.floor!,
          building: meta.buildingID!,
          peak: e.rssi, n: 1,
        );
      }
    }
    if (agg.isEmpty) return null;

    // ── 4. RSSI penalty for sparse readings ──────────────────────────────
    for (final b in agg.values) {
      b.penPeak = b.peak.toDouble() +
          (b.n == 1 ? -4.0 : b.n == 2 ? -2.0 : 0.0);
    }

    // ── 5. Building selection ────────────────────────────────────────────
    // Must happen before the floor vote: floor numbers are only unique within
    // a building, and each building has its own floor-plan coordinate grid.
    // Mixing two buildings would average coordinates from unrelated grids.
    final targetBuilding = building ?? _selectBuilding(agg);
    final bldEntries = agg.entries
        .where((e) => e.value.building == targetBuilding)
        .toList();
    if (bldEntries.isEmpty) return null;

    // Entering a different building invalidates every piece of smoothing
    // state — the old EMA position, velocity cap and continuity set all refer
    // to a coordinate grid that no longer applies.
    final buildingChanged =
        _currBuilding != null && _currBuilding != targetBuilding;
    if (buildingChanged) {
      _emaPos     = null;
      _prevTop2   = {};
      _prevR1     = null;
      _prevRawPos = null;
    }
    _currBuilding = targetBuilding;

    // ── 6. Floor selection (within the chosen building) ──────────────────
    final targetFloor = floor ?? _majorityFloor(bldEntries);
    final floorEntries = bldEntries
        .where((e) => e.value.floor == targetFloor)
        .toList();
    if (floorEntries.isEmpty) return null;

    // ── 7. Continuity bonus + re-rank ────────────────────────────────────
    for (final e in floorEntries) {
      e.value.score = e.value.penPeak +
          (_prevTop2.contains(e.key) ? _continuityBonus : 0.0);
    }
    floorEntries.sort((a, b) => b.value.score.compareTo(a.value.score));

    // ── 8. Softmax weighted centroid on top-N ────────────────────────────
    final top    = floorEntries.take(topN).toList();
    final rssis  = top.map((e) => e.value.penPeak).toList();
    final maxR   = rssis.reduce(max);
    final expW   = rssis.map((r) => exp((r - maxR) / temp)).toList();
    final sumW   = expW.fold(0.0, (a, b) => a + b);
    final wNorm  = expW.map((w) => w / sumW).toList();

    double rawX = 0, rawY = 0;
    for (int i = 0; i < top.length; i++) {
      rawX += wNorm[i] * top[i].value.lx;
      rawY += wNorm[i] * top[i].value.ly;
    }

    final currTop2 = top.take(2).map((e) => e.key).toSet();
    final currR1   = floorEntries.first.key;
    final rssiGap  = floorEntries.length > 1
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

    final alpha   = isWalking ? _alphaWalking   : _alphaStationary;
    final maxJump = isWalking ? _maxJumpWalk     : _maxJumpStat;

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

    final sx = _emaPos![0], sy = _emaPos![1];

    // ── 11. GPS estimate (anchors from this building only) ───────────────
    final gps = _localToGps(sx, sy, targetBuilding);

    // Update rolling state
    _prevTop2   = currTop2;
    _prevR1     = currR1;
    _prevRawPos = [rawX, rawY];

    final topW = wNorm.isNotEmpty ? wNorm[0] : 0.0;

    return PositionResult(
      smoothX:     sx,
      smoothY:     sy,
      rawX:        rawX,
      rawY:        rawY,
      smoothLat:   gps?[0],
      smoothLon:   gps?[1],
      confidence:  _confidence(top.length, floorEntries.first.value.penPeak, topW),
      motionState: isWalking ? 'walking' : 'stationary',
      building:    targetBuilding,
      floor:       targetFloor,
      buildingChanged: buildingChanged,
      rank1Beacon: floorEntries.first.key,
      rank1Rssi:   floorEntries.first.value.peak,
      rank1Weight: topW,
      jumpPx:      jumpPx,
      nBeacons:    floorEntries.length,
    );
  }

  // ── Reset all state (call when starting a new session) ─────────────────
  void reset() {
    _buf.clear();
    _emaPos       = null;
    _prevTop2     = {};
    _prevR1       = null;
    _prevRawPos   = null;
    _currBuilding = null;
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

    final leader =
        best.entries.reduce((a, b) => a.value >= b.value ? a : b);

    final curr = _currBuilding;
    if (curr == null || !best.containsKey(curr)) {
      // No incumbent, or it has dropped out of the window entirely.
      return leader.key;
    }
    return leader.value > best[curr]! + _bldSwitchMargin ? leader.key : curr;
  }

  int _majorityFloor(List<MapEntry<String, _Agg>> entries) {
    final counts = <int, int>{};
    for (final e in entries) {
      counts[e.value.floor] = (counts[e.value.floor] ?? 0) + 1;
    }
    return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  List<double>? _localToGps(double lx, double ly, String building) {
    double tw = 0, la = 0, lo = 0;
    for (final m in beaconDb.values) {
      // Anchors from another building sit on a different pixel grid, so their
      // distance to (lx, ly) is meaningless.
      if (m.buildingID != building) continue;
      final lat = double.tryParse(m.properties?.latitude ?? '');
      final lon = double.tryParse(m.properties?.longitude ?? '');
      if (lat == null || lon == null) continue;
      if (m.coordinateX == null || m.coordinateY == null) continue;
      final dx = lx - m.coordinateX!, dy = ly - m.coordinateY!;
      final d  = max(sqrt(dx * dx + dy * dy), 0.5);
      final w  = 1.0 / (d * d);
      la += w * lat;
      lo += w * lon;
      tw += w;
    }
    if (tw == 0) return null;
    return [la / tw, lo / tw];
  }

  String _confidence(int n, double bestRssi, double topW) {
    int s = 0;
    if (topW > 0.55)    s += 3;
    else if (topW > 0.35) s += 2;
    else s += 1;
    if (n >= 5)           s += 2;
    else if (n >= 3)      s += 1;
    if (bestRssi >= -75)  s += 2;
    else if (bestRssi >= -85) s += 1;
    return s >= 6 ? 'high' : s >= 4 ? 'medium' : 'low';
  }
}
