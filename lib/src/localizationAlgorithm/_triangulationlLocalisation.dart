import 'dart:math';

// ═══════════════════════════════════════════════════════════════════════════
// HOW THE SOLVER WORKS
// ═══════════════════════════════════════════════════════════════════════════
//
//  Each beacon defines a circle: centre = beacon position, radius = RSSI→distance.
//  The device is at the intersection of those circles.
//
//  Real-world RSSI is noisy, so three cases arise:
//
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │ Case 1 – Circles too SMALL (non-intersecting)                       │
//  │   Inflate all radii by the same factor (binary search) until every  │
//  │   pair of circles just overlaps, then trilaterate.                  │
//  │   This is the "circle inflation" strategy the user requested.       │
//  ├─────────────────────────────────────────────────────────────────────┤
//  │ Case 2 – Circles too LARGE (overlap outside the beacon triangle)    │
//  │   Closed-form trilateration gives a point far outside / negative.   │
//  │   Fall back to gradient-descent least-squares, which always finds   │
//  │   the finite point that minimises Σ(dist - radius)².                │
//  ├─────────────────────────────────────────────────────────────────────┤
//  │ Case 3 – Circles intersect nicely inside the triangle (ideal)       │
//  │   Closed-form trilateration gives an exact answer directly.         │
//  └─────────────────────────────────────────────────────────────────────┘
//
//  4-BEACON MULTI-TRIANGULATION
//  When exactly 4 beacons are supplied the solver runs three overlapping
//  batches of 3 beacons each:
//    Batch 1 → beacons [0, 1, 2]
//    Batch 2 → beacons [1, 2, 3]
//    Batch 3 → beacons [2, 3, 0]
//  Each batch produces a TriangulationResult via the normal 3-beacon solver.
//  The three estimated positions are then combined into a single resultant
//  using accuracy-weighted averaging: better-accuracy results pull the final
//  estimate closer to themselves.  The combined result is returned as a
//  FourBeaconTriangulationResult which also exposes the three batch results.
//
//  UNIT MISMATCH WARNING
//  rssiToDistance() returns metres by default.
//  If your x/y coordinates are in feet, pass distanceScale = 3.28084.
//  If they are pixels where 1 px = 0.5 m, pass distanceScale = 2.0, etc.
// ═══════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────
// Data types
// ─────────────────────────────────────────────────────────────────────────

class Point2D {
  final double x;
  final double y;

  const Point2D(this.x, this.y);

  double distanceTo(Point2D other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return sqrt(dx * dx + dy * dy);
  }

  @override
  String toString() =>
      'Point2D(x: ${x.toStringAsFixed(4)}, y: ${y.toStringAsFixed(4)})';
}

class Beacon {
  final String id;
  final Point2D location; // in YOUR local coordinate unit (feet, pixels, …)
  final double rssi;      // dBm, typically negative

  const Beacon({required this.id, required this.location, required this.rssi});

  @override
  String toString() => 'Beacon(id: $id, location: $location, rssi: $rssi)';
}

class TriangulationResult {
  /// Estimated position in the same unit as your beacon coordinates.
  final Point2D estimatedPosition;

  /// Distance from each beacon to the estimate, in local units.
  final List<double> distances;

  /// Human-readable description of which solver branch was used.
  final String method;

  /// Rough accuracy estimate in local units (lower is better).
  final double? accuracy;

  const TriangulationResult({
    required this.estimatedPosition,
    required this.distances,
    required this.method,
    this.accuracy,
  });

  @override
  String toString() =>
      'TriangulationResult(\n'
          '  method        : $method\n'
          '  position      : $estimatedPosition\n'
          '  distances     : ${distances.map((d) => d.toStringAsFixed(2)).toList()}\n'
          '  est. accuracy : ${accuracy != null ? "${accuracy!.toStringAsFixed(2)} local units" : "n/a"}\n'
          ')';
}

// ─────────────────────────────────────────────────────────────────────────
// 4-Beacon result type
// ─────────────────────────────────────────────────────────────────────────

/// Result returned when exactly 4 beacons are supplied.
///
/// [batchResults] holds the three individual 3-beacon estimates:
///   index 0 → batch (B0, B1, B2)
///   index 1 → batch (B1, B2, B3)
///   index 2 → batch (B2, B3, B0)
///
/// [estimatedPosition] is the accuracy-weighted centroid of those three
/// estimates — a better-quality batch pulls the final point closer to it.
class FourBeaconTriangulationResult {
  final Point2D estimatedPosition;
  final List<TriangulationResult> batchResults;
  final double? accuracy;

  const FourBeaconTriangulationResult({
    required this.estimatedPosition,
    required this.batchResults,
    this.accuracy,
  });

  @override
  String toString() {
    final sb = StringBuffer();
    sb.writeln('FourBeaconTriangulationResult(');
    sb.writeln('  final position  : $estimatedPosition');
    sb.writeln('  est. accuracy   : ${accuracy != null ? "${accuracy!.toStringAsFixed(2)} local units" : "n/a"}');
    for (int i = 0; i < batchResults.length; i++) {
      sb.writeln('  ── Batch ${i + 1} ──────────────────────────────────────');
      for (final line in batchResults[i].toString().split('\n')) {
        sb.writeln('  $line');
      }
    }
    sb.write(')');
    return sb.toString();
  }
}

// ─────────────────────────────────────────────────────────────────────────
// RSSI → distance
// ─────────────────────────────────────────────────────────────────────────

/// Log-distance path-loss model:  distance = 10^((txPower − rssi) / (10·n))
///
/// The formula produces **metres**.  Multiply by [distanceScale] to match
/// whatever unit your beacon x/y coordinates use.
///
/// Common [distanceScale] values:
///   1.0      → metres  (default)
///   3.28084  → feet
///   100.0    → centimetres
///   Set to (local units / 1 metre) for any other unit.
///
/// [txPower]          – calibrated RSSI at 1 m (dBm, default −59).
/// [pathLossExponent] – n: 2.0 free-space … 4.0 heavy walls.
double rssiToDistance(
    double rssi, {
      double txPower = -70.0,
      double pathLossExponent = 3.0,
      double distanceScale = 1.0,
    }) {
  if (rssi >= 0) return 0.0;
  final metres =
  pow(10.0, (txPower - rssi) / (10.0 * pathLossExponent)).toDouble();
  return metres * distanceScale;
}

// ─────────────────────────────────────────────────────────────────────────
// Low-level geometry
// ─────────────────────────────────────────────────────────────────────────

/// Returns the intersection point(s) of two circles, or null if they
/// don't intersect (too far apart or one inside the other).
List<Point2D>? _circleIntersections(
    Point2D c1, double r1,
    Point2D c2, double r2,
    ) {
  final dx = c2.x - c1.x;
  final dy = c2.y - c1.y;
  final d = sqrt(dx * dx + dy * dy);

  if (d > r1 + r2 + 1e-9) return null;
  if (d < (r1 - r2).abs() - 1e-9) return null;
  if (d < 1e-9) return null;

  final a = (r1 * r1 - r2 * r2 + d * d) / (2 * d);
  final h2 = r1 * r1 - a * a;
  if (h2 < 0) return null;
  final h = sqrt(h2);

  final mx = c1.x + a * dx / d;
  final my = c1.y + a * dy / d;

  if (h < 1e-9) return [Point2D(mx, my)]; // tangent

  return [
    Point2D(mx + h * dy / d, my - h * dx / d),
    Point2D(mx - h * dy / d, my + h * dx / d),
  ];
}

Point2D _midpoint(Point2D a, Point2D b) =>
    Point2D((a.x + b.x) / 2, (a.y + b.y) / 2);

/// True when every pair of circles has at least one intersection point.
bool _allPairsIntersect(List<Point2D> centres, List<double> radii) {
  for (int i = 0; i < centres.length; i++) {
    for (int j = i + 1; j < centres.length; j++) {
      final d = centres[i].distanceTo(centres[j]);
      final ri = radii[i], rj = radii[j];
      if (d > ri + rj + 1e-9) return false;
      if (d < (ri - rj).abs() - 1e-9) return false;
    }
  }
  return true;
}

// ─────────────────────────────────────────────────────────────────────────
// Circle inflation  (Case 1 — circles too small)
// ─────────────────────────────────────────────────────────────────────────

/// Binary-searches for the minimum scale factor ≥ 1 such that every pair
/// of circles (scaled uniformly) has at least one intersection.
///
/// Returns 1.0 immediately if they already intersect.
/// Returns null if no finite scale achieves intersection (e.g. all beacons
/// at the same point with different radii).
double? _inflationScale(
    List<Point2D> centres,
    List<double> radii, {
      double maxScale = 1000.0,
      int iterations = 60,
    }) {
  if (_allPairsIntersect(centres, radii)) return 1.0;

  // Check if maxScale is sufficient
  if (!_allPairsIntersect(
      centres, radii.map((r) => r * maxScale).toList())) {
    return null;
  }

  double lo = 1.0, hi = maxScale;
  for (int i = 0; i < iterations; i++) {
    final mid = (lo + hi) / 2;
    if (_allPairsIntersect(centres, radii.map((r) => r * mid).toList())) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
}

// ─────────────────────────────────────────────────────────────────────────
// Least-squares gradient descent  (Case 2 — circles overlap outside)
// ─────────────────────────────────────────────────────────────────────────

/// Finds the point P that minimises  Σᵢ (‖P − cᵢ‖ − rᵢ)²
/// via gradient descent with an adaptive step size and gradient clipping.
Point2D _leastSquares(
    List<Point2D> centres,
    List<double> radii, {
      int iterations = 2000,
    }) {
  // Initialise at inverse-distance weighted centroid (closer beacon = more weight)
  final weights = radii.map((r) => 1.0 / (r + 1e-9)).toList();
  final totalW = weights.fold(0.0, (s, w) => s + w);
  double px = 0, py = 0;
  for (int i = 0; i < centres.length; i++) {
    px += weights[i] * centres[i].x;
    py += weights[i] * centres[i].y;
  }
  px /= totalW;
  py /= totalW;

  // Scale step size to the geometry — safe for any unit (feet, metres, pixels…)
  final baseLr = radii.reduce(min) * 0.1;

  for (int iter = 0; iter < iterations; iter++) {
    double gx = 0, gy = 0;
    for (int i = 0; i < centres.length; i++) {
      final dx = px - centres[i].x;
      final dy = py - centres[i].y;
      final dist = sqrt(dx * dx + dy * dy);
      if (dist < 1e-9) continue;
      final err = dist - radii[i];
      gx += err * dx / dist;
      gy += err * dy / dist;
    }

    // Gradient clipping
    final gMag = sqrt(gx * gx + gy * gy);
    if (gMag > 1.0) {
      gx /= gMag;
      gy /= gMag;
    }

    // Decaying LR
    final lr = baseLr / (1.0 + iter * 0.001);
    px -= lr * gx;
    py -= lr * gy;
  }

  return Point2D(px, py);
}

// ─────────────────────────────────────────────────────────────────────────
// Closed-form trilateration
// ─────────────────────────────────────────────────────────────────────────

/// Exact closed-form solution for 3 circles by linearising via subtraction.
/// Returns null when beacons are collinear (degenerate determinant).
Point2D? _trilaterate3(
    Point2D p1, double d1,
    Point2D p2, double d2,
    Point2D p3, double d3,
    ) {
  final x2 = p2.x - p1.x, y2 = p2.y - p1.y;
  final x3 = p3.x - p1.x, y3 = p3.y - p1.y;

  final A = 2 * x2, B = 2 * y2;
  final C = d1 * d1 - d2 * d2 + x2 * x2 + y2 * y2;
  final D = 2 * x3, E = 2 * y3;
  final F = d1 * d1 - d3 * d3 + x3 * x3 + y3 * y3;

  final det = A * E - B * D;
  if (det.abs() < 1e-9) return null;

  return Point2D(
    (C * E - F * B) / det + p1.x,
    (A * F - D * C) / det + p1.y,
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Bounding-box sanity check
// ─────────────────────────────────────────────────────────────────────────

bool _isInsideBoundingBox(
    Point2D p,
    List<Point2D> beaconPositions, {
      double margin = 0.5,
    }) {
  double minX = double.infinity, maxX = -double.infinity;
  double minY = double.infinity, maxY = -double.infinity;
  for (final b in beaconPositions) {
    if (b.x < minX) minX = b.x;
    if (b.x > maxX) maxX = b.x;
    if (b.y < minY) minY = b.y;
    if (b.y > maxY) maxY = b.y;
  }
  final span = sqrt((maxX - minX) * (maxX - minX) + (maxY - minY) * (maxY - minY));
  final expand = span * margin;
  return p.x >= minX - expand &&
      p.x <= maxX + expand &&
      p.y >= minY - expand &&
      p.y <= maxY + expand;
}

// ─────────────────────────────────────────────────────────────────────────
// Residual helper
// ─────────────────────────────────────────────────────────────────────────

double _avgResidual(Point2D p, List<Point2D> centres, List<double> radii) {
  double sum = 0;
  for (int i = 0; i < centres.length; i++) {
    sum += (p.distanceTo(centres[i]) - radii[i]).abs();
  }
  return sum / centres.length;
}

// ─────────────────────────────────────────────────────────────────────────
// Per-mode solvers
// ─────────────────────────────────────────────────────────────────────────

TriangulationResult _singleBeacon(Beacon b, double d) {
  return TriangulationResult(
    estimatedPosition: b.location,
    distances: [d],
    method: 'single-beacon (proximity only — on circle of radius ${d.toStringAsFixed(1)})',
    accuracy: d,
  );
}

TriangulationResult _twoBeacon(Beacon b1, double d1, Beacon b2, double d2) {
  final centres = [b1.location, b2.location];
  final radii   = [d1, d2];

  final intersections = _circleIntersections(b1.location, d1, b2.location, d2);

  if (intersections != null && intersections.isNotEmpty) {
    if (intersections.length == 1) {
      return TriangulationResult(
        estimatedPosition: intersections.first,
        distances: [d1, d2],
        method: 'two-beacon (tangent point)',
        accuracy: 0,
      );
    }
    final mid = _midpoint(intersections[0], intersections[1]);
    return TriangulationResult(
      estimatedPosition: mid,
      distances: [d1, d2],
      method: 'two-beacon (midpoint of intersection candidates)',
      accuracy: intersections[0].distanceTo(intersections[1]) / 2,
    );
  }

  final scale = _inflationScale(centres, radii);
  if (scale != null && scale > 1.0) {
    final inflated = [d1 * scale, d2 * scale];
    final pts = _circleIntersections(b1.location, inflated[0], b2.location, inflated[1]);
    if (pts != null && pts.length == 2) {
      final mid = _midpoint(pts[0], pts[1]);
      return TriangulationResult(
        estimatedPosition: mid,
        distances: [d1, d2],
        method: 'two-beacon (inflated ×${scale.toStringAsFixed(2)} → midpoint)',
        accuracy: pts[0].distanceTo(pts[1]) / 2,
      );
    }
  }

  final ls = _leastSquares(centres, radii);
  return TriangulationResult(
    estimatedPosition: ls,
    distances: [d1, d2],
    method: 'two-beacon (least-squares)',
    accuracy: _avgResidual(ls, centres, radii),
  );
}

TriangulationResult _threeBeacon(
    Beacon b1, double d1,
    Beacon b2, double d2,
    Beacon b3, double d3,
    ) {
  final centres  = [b1.location, b2.location, b3.location];
  final radii    = [d1, d2, d3];

  // ── Step 1: try exact closed-form ────────────────────────────────────
  final cf = _trilaterate3(b1.location, d1, b2.location, d2, b3.location, d3);

  if (cf != null && _isInsideBoundingBox(cf, centres)) {
    return TriangulationResult(
      estimatedPosition: cf,
      distances: radii,
      method: 'three-beacon (closed-form trilateration)',
      accuracy: _avgResidual(cf, centres, radii),
    );
  }

  // ── Step 2: circles don't fully intersect → inflate ─────────────────
  if (!_allPairsIntersect(centres, radii)) {
    final scale = _inflationScale(centres, radii);
    if (scale != null) {
      final inflatedRadii = radii.map((r) => r * scale).toList();
      final cfInflated = _trilaterate3(
        b1.location, inflatedRadii[0],
        b2.location, inflatedRadii[1],
        b3.location, inflatedRadii[2],
      );
      if (cfInflated != null && _isInsideBoundingBox(cfInflated, centres)) {
        return TriangulationResult(
          estimatedPosition: cfInflated,
          distances: radii,
          method:
          'three-beacon (circle inflation ×${scale.toStringAsFixed(2)} → trilateration)',
          accuracy: _avgResidual(cfInflated, centres, radii),
        );
      }
    }
  }

  // ── Step 3: least-squares fallback ───────────────────────────────────
  final ls = _leastSquares(centres, radii);
  String method;
  if (cf == null) {
    method = 'three-beacon (collinear beacons → least-squares)';
  } else if (!_allPairsIntersect(centres, radii)) {
    method = 'three-beacon (non-intersecting → least-squares)';
  } else {
    method = 'three-beacon (intersection outside triangle → least-squares)';
  }

  return TriangulationResult(
    estimatedPosition: ls,
    distances: radii,
    method: method,
    accuracy: _avgResidual(ls, centres, radii),
  );
}

// ─────────────────────────────────────────────────────────────────────────
// 4-Beacon multi-triangulation
// ─────────────────────────────────────────────────────────────────────────

/// Runs three overlapping 3-beacon batches and combines the results into a
/// single accuracy-weighted position estimate.
///
/// Given beacons sorted by signal strength [B0, B1, B2, B3]:
///   Batch 1 → (B0, B1, B2)
///   Batch 2 → (B1, B2, B3)
///   Batch 3 → (B2, B3, B0)
///
/// Each batch produces its own [TriangulationResult] via the normal
/// 3-beacon solver.  The final position is the **accuracy-weighted centroid**
/// of the three estimates:
///
///   weight_i = 1 / (accuracy_i + ε)    ← lower error = higher weight
///   x_final  = Σ(weight_i · x_i) / Σ weight_i
///   y_final  = Σ(weight_i · y_i) / Σ weight_i
///
/// This means a batch whose circles intersect cleanly (small residual)
/// pulls the final answer toward itself more than a noisy batch.
FourBeaconTriangulationResult _fourBeacon(
    List<Beacon> top4,
    List<double> distances,
    ) {
  assert(top4.length == 4 && distances.length == 4);

  // Define the three index triplets: (0,1,2), (1,2,3), (2,3,0)
  final triplets = [
    [0, 1, 2],
    [1, 2, 3],
    [2, 3, 0],
  ];

  final batchResults = <TriangulationResult>[];

  for (final t in triplets) {
    final result = _threeBeacon(
      top4[t[0]], distances[t[0]],
      top4[t[1]], distances[t[1]],
      top4[t[2]], distances[t[2]],
    );
    batchResults.add(result);
  }

  // Accuracy-weighted centroid of the three batch estimates.
  // If a batch has null accuracy we assign a generous fallback penalty so it
  // still contributes but with lower weight than a well-solved batch.
  const fallbackAccuracy = 1e6;
  final weights = batchResults
      .map((r) => 1.0 / ((r.accuracy ?? fallbackAccuracy) + 1e-9))
      .toList();
  final totalW = weights.fold(0.0, (s, w) => s + w);

  double wx = 0, wy = 0;
  for (int i = 0; i < batchResults.length; i++) {
    wx += weights[i] * batchResults[i].estimatedPosition.x;
    wy += weights[i] * batchResults[i].estimatedPosition.y;
  }
  final combined = Point2D(wx / totalW, wy / totalW);

  // All four centres for the residual calculation
  final allCentres = top4.map((b) => b.location).toList();
  final combinedAccuracy = _avgResidual(combined, allCentres, distances);

  return FourBeaconTriangulationResult(
    estimatedPosition: combined,
    batchResults: batchResults,
    accuracy: combinedAccuracy,
  );
}

// ─────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────

/// Estimates the observer's 2-D position from 1, 2, 3, or 4 BLE beacons.
///
/// • **1 beacon** → proximity (position = beacon location, accuracy = radius).
/// • **2 beacons** → circle intersection or least-squares.
/// • **3 beacons** → closed-form trilateration, circle inflation, or
///                   least-squares (whichever suits the geometry).
/// • **4 beacons** → multi-triangulation: three overlapping 3-beacon batches
///                   whose results are combined via accuracy-weighted averaging.
///                   Returns a [FourBeaconTriangulationResult].
/// • **5+ beacons** → the 4 with the strongest signal are used (4-beacon path).
///
/// ### `distanceScale` — the most important parameter to get right
/// `rssiToDistance` outputs **metres**.  Your x/y coordinates may use a
/// different unit.  Set `distanceScale` = local-units-per-metre:
///
///   Feet   → distanceScale = 3.28084
///   Inches → distanceScale = 39.3701
///   cm     → distanceScale = 100.0
///   Custom → distanceScale = (local units) / (1 metre)
///
/// ### Other parameters
///   [txPower]           – calibrated RSSI at 1 m (dBm, default −70).
///   [pathLossExponent]  – n: 2.0 free-space … 4.0 heavy walls.
///
/// The return type is [TriangulationResult] for 1–3 beacons and
/// [FourBeaconTriangulationResult] (a subtype) for 4+ beacons.
dynamic triangulate(
    List<Beacon> beacons, {
      double txPower = -70.0,
      double pathLossExponent = 3.0,
      double distanceScale = 3.28084,
    }) {
  if (beacons.isEmpty) throw ArgumentError('At least one beacon is required.');

  // Sort by strongest signal first (least-negative RSSI = closest beacon)
  final sorted = [...beacons]..sort((a, b) => b.rssi.compareTo(a.rssi));

  if (sorted.length > 4) {
    print('[triangulate] ${sorted.length} beacons supplied; '
        'using the 4 strongest.');
  }

  final top = sorted.take(4).toList();

  final distances = top
      .map((b) => rssiToDistance(
    b.rssi,
    txPower: txPower,
    pathLossExponent: pathLossExponent,
    distanceScale: distanceScale,
  ))
      .toList();

  switch (top.length) {
    case 1:
      return _singleBeacon(top[0], distances[0]);
    case 2:
      return _twoBeacon(top[0], distances[0], top[1], distances[1]);
    case 3:
      return _threeBeacon(
        top[0], distances[0],
        top[1], distances[1],
        top[2], distances[2],
      );
    default: // 4 beacons
      return _fourBeacon(top, distances);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Demo
// ─────────────────────────────────────────────────────────────────────────

void main() {
  print('══════════════════════════════════════════════════════════════');
  print('            BEACON TRIANGULATION DEMO  (1–4 beacons)');
  print('══════════════════════════════════════════════════════════════\n');

  // ── 3-beacon scenario (unchanged behaviour) ──────────────────────────
  print('─── 3-beacon scenario ───────────────────────────────────────');
  final beacons3 = [
    Beacon(id: 'A', location: const Point2D(19, 32), rssi: -96.66666666666667),
    Beacon(id: 'B', location: const Point2D(64, 32), rssi: -88.25),
    Beacon(id: 'C', location: const Point2D(94, 25), rssi: -94.0),
  ];
  print(triangulate(beacons3, txPower: -75.0, pathLossExponent: 3.0, distanceScale: 3.28084));

  print('');

  // ── 4-beacon scenario ────────────────────────────────────────────────
  print('─── 4-beacon scenario ───────────────────────────────────────');
  final beacons4 = [
    Beacon(id: 'A', location: const Point2D(19, 32),  rssi: -96.66666666666667),
    Beacon(id: 'B', location: const Point2D(64, 32),  rssi: -88.25),
    Beacon(id: 'C', location: const Point2D(94, 25),  rssi: -94.0),
    Beacon(id: 'D', location: const Point2D(50, 10),  rssi: -91.0),
  ];
  final result4 = triangulate(
    beacons4,
    txPower: -75.0,
    pathLossExponent: 3.0,
    distanceScale: 3.28084,
  ) as FourBeaconTriangulationResult;

  print(result4);
}