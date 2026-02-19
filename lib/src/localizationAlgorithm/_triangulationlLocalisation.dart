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
      double txPower = -59.0,
      double pathLossExponent = 2.0,
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
///
/// ### Why these two fixes prevent NaN
/// **Adaptive base LR** (`min(radii) * 0.1`): a fixed LR of 2.0 is way too
/// large when radii are small (e.g. 9 ft).  The raw gradient magnitude grows
/// inversely with radius, so the position explodes to ±Inf in a few steps.
/// Tying the LR to the smallest radius keeps the update proportionate to the
/// problem scale regardless of what unit system or txPower you use.
///
/// **Gradient clipping** (normalise to unit vector): caps the step to exactly
/// `baseLr` on the first few chaotic iterations before convergence.  Once the
/// gradient is naturally small the clip has no effect.
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
      final err = dist - radii[i]; // + = too far from beacon, − = too close
      gx += err * dx / dist;
      gy += err * dy / dist;
    }

    // Gradient clipping: if the raw gradient is large, normalise to unit
    // length so each step is at most baseLr — prevents exploding updates.
    final gMag = sqrt(gx * gx + gy * gy);
    if (gMag > 1.0) {
      gx /= gMag;
      gy /= gMag;
    }

    // Decaying LR: big steps early for speed, tiny steps later for precision
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

/// Returns true if [p] lies within [margin] local units of the beacon
/// bounding box — a quick plausibility test for closed-form results.
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
  // Expand by the largest circle radius as a generous margin
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

  // Try intersection first
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

  // Circles don't intersect — inflate then least-squares
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

  // Absolute fallback: least-squares
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
  final beacons  = [b1, b2, b3];

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
          distances: radii, // report original distances, not inflated
          method:
          'three-beacon (circle inflation ×${scale.toStringAsFixed(2)} → trilateration)',
          accuracy: _avgResidual(cfInflated, centres, radii),
        );
      }
    }
  }

  // ── Step 3: circles overlap but outside triangle → least-squares ─────
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
// Public API
// ─────────────────────────────────────────────────────────────────────────

/// Estimates the observer's 2-D position from 1, 2, or 3 BLE beacons.
///
/// The solver automatically selects the best strategy:
///   • Exact trilateration     — when circles intersect inside the beacon area.
///   • Circle inflation        — when circles are too small (non-intersecting):
///                               inflates all radii proportionally until they
///                               just overlap, then trilaterates.
///   • Least-squares descent   — when circles overlap outside the beacon area
///                               (noisy RSSI): finds the point that minimises
///                               Σ(distance − radius)² — always finite.
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
///   [txPower]           – calibrated RSSI at 1 m (dBm, default −59).
///   [pathLossExponent]  – n: 2.0 free-space … 4.0 heavy walls.
///
/// If more than 3 beacons are supplied the 3 with the strongest signal are used.
TriangulationResult triangulate(
    List<Beacon> beacons, {
      double txPower = -59.0,
      double pathLossExponent = 2.0,
      double distanceScale = 1.0,
    }) {
  if (beacons.isEmpty) throw ArgumentError('At least one beacon is required.');

  // Sort by strongest signal first (least-negative = closest)
  final sorted = [...beacons]..sort((a, b) => b.rssi.compareTo(a.rssi));
  if (sorted.length > 3) {
    print('[triangulate] ${sorted.length} beacons supplied; '
        'using the 3 strongest.');
  }
  final top = sorted.take(3).toList();

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
    default:
      return _threeBeacon(
        top[0], distances[0],
        top[1], distances[1],
        top[2], distances[2],
      );
  }
}

void main() {
  print('══════════════════════════════════════════════════════════════');
  print('                  BEACON TRIANGULATION DEMO');
  print('══════════════════════════════════════════════════════════════\n');

  final beaconsIndoor = [
    Beacon(id: 'A', location: const Point2D(19, 32),  rssi: -96.66666666666667),
    Beacon(id: 'B', location: const Point2D(64, 32), rssi: -88.25),
    Beacon(id: 'C', location: const Point2D(94, 25),  rssi: -94.0),
  ];
  print(triangulate(beaconsIndoor, txPower: -75.0, pathLossExponent: 3.0, distanceScale: 3.28084));
}