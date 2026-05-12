/// BLE Indoor Localization — Flutter/Dart
/// ========================================
/// Drop-in inference engine. No dependencies beyond dart:convert and dart:math.
/// Load model JSON once at startup, call predict() on every scan.
///
/// Usage:
///   final loc = await BLELocalizer.fromAsset('assets/ble_model.json');
///   final result = loc.predict(scanMap);
///   print('X=${result.x}  Y=${result.y}  error≈${result.nearestZone}');

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;

// ── Data classes ─────────────────────────────────────────────────────

class LocalizationResult {
  /// Predicted coordinates in pixel space
  final double x;
  final double y;
  final int floor;

  /// Real-world estimate (metres from origin)
  final double xMetres;
  final double yMetres;

  /// Label of nearest reference zone e.g. "137_334"
  final String nearestZone;

  /// Distance to nearest reference zone in metres
  final double nearestZoneDistM;

  /// Gaussian confidence [0–1]. 1.0 = model is certain.
  final double confidence;

  /// Top-3 candidate zones with probabilities
  final List<ZoneCandidate> topCandidates;

  const LocalizationResult({
    required this.x,
    required this.y,
    required this.floor,
    required this.xMetres,
    required this.yMetres,
    required this.nearestZone,
    required this.nearestZoneDistM,
    required this.confidence,
    required this.topCandidates,
  });

  @override
  String toString() =>
      'LocalizationResult(x=$x, y=$y, floor=$floor, '
      'nearestZone=$nearestZone, conf=${(confidence * 100).toStringAsFixed(1)}%)';
}

class ZoneCandidate {
  final String label;
  final double x;
  final double y;
  final int floor;
  final double probability;

  const ZoneCandidate({
    required this.label,
    required this.x,
    required this.y,
    required this.floor,
    required this.probability,
  });

  @override
  String toString() =>
      'ZoneCandidate(label=$label, x=${x.toStringAsFixed(2)}, '
          'y=${y.toStringAsFixed(2)}, floor=$floor, '
          'prob=${(probability * 100).toStringAsFixed(1)}%)';

  String toStringWithGroundTruth(int gtX, int gtY, double scaleMPx) {
    final bar = '█' * (probability * 20).round();
    final empty = '░' * (20 - (probability * 20).round());
    final dist = sqrt(pow(x - gtX, 2) + pow(y - gtY, 2)) * scaleMPx;
    return '''
┌─ ZoneCandidate ──────────────────┐
│ Label  : $label
│ X      : ${x.toStringAsFixed(2)} px
│ Y      : ${y.toStringAsFixed(2)} px
│ Floor  : $floor
│ Dist   : ${dist.toStringAsFixed(2)} m from ($gtX, $gtY)
│ Prob   : ${(probability * 100).toStringAsFixed(1)}% $bar$empty
└───────────────────────────────────┘''';
  }
}

// ── Model ─────────────────────────────────────────────────────────────

class BLELocalizer {
  final List<String> _beaconIds;
  final double _scaleMPx;
  final double _bleMin;
  final double _bleMax;
  final double _noSignal;

  // WKNN
  final int _k;
  final List<List<double>> _xTrain; // [n_sessions, n_beacons]
  final List<List<double>> _yTrain; // [n_sessions, 2]

  // Gaussian: location → beacon → {mu, sigma}
  final Map<String, _GaussLoc> _gaussLocs;

  BLELocalizer._({
    required List<String> beaconIds,
    required double scaleMPx,
    required double bleMin,
    required double bleMax,
    required double noSignal,
    required int k,
    required List<List<double>> xTrain,
    required List<List<double>> yTrain,
    required Map<String, _GaussLoc> gaussLocs,
  })  : _beaconIds = beaconIds,
        _scaleMPx = scaleMPx,
        _bleMin = bleMin,
        _bleMax = bleMax,
        _noSignal = noSignal,
        _k = k,
        _xTrain = xTrain,
        _yTrain = yTrain,
        _gaussLocs = gaussLocs;

  // ── Factory constructors ────────────────────────────────────────────

  /// Load from Flutter assets bundle (place ble_model.json in assets/)
  static Future<BLELocalizer> fromAsset(String fileName) async {
    final scriptDir = File(Platform.script.toFilePath()).parent;
    final file = File('${scriptDir.path}/$fileName');

    final contents = await file.readAsString();
    return fromJson(contents);
  }

  /// Load from a JSON string directly
  static BLELocalizer fromJson(String jsonStr) {
    final Map<String, dynamic> data = json.decode(jsonStr);
    final beaconIds = List<String>.from(data['beacon_ids']);
    final scaleMPx = (data['scale_m_px'] as num).toDouble();
    final bleMin = (data['ble_min'] as num).toDouble();
    final bleMax = (data['ble_max'] as num).toDouble();
    final noSignal = (data['no_signal'] as num).toDouble();

    // WKNN
    final wknnData = data['wknn'] as Map<String, dynamic>;
    final k = wknnData['k'] as int;
    final xTrain = (wknnData['X_train'] as List)
        .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
        .toList();
    final yTrain = (wknnData['y_train'] as List)
        .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
        .toList();

    // Gaussian
    final gaussData = data['gaussian']['locations'] as Map<String, dynamic>;
    final gaussLocs = <String, _GaussLoc>{};
    gaussData.forEach((label, locData) {
      final ld = locData as Map<String, dynamic>;
      final beaconMap = <String, _GaussParam>{};
      (ld['beacons'] as Map<String, dynamic>).forEach((beacon, params) {
        final p = params as Map<String, dynamic>;
        beaconMap[beacon] = _GaussParam(
          mu: (p['mu'] as num).toDouble(),
          sigma: (p['sigma'] as num).toDouble(),
        );
      });
      gaussLocs[label] = _GaussLoc(
        x: (ld['x'] as num).toDouble(),
        y: (ld['y'] as num).toDouble(),
        floor: (ld['floor'] as num).toInt(),
        beacons: beaconMap,
      );
    });

    return BLELocalizer._(
      beaconIds: beaconIds,
      scaleMPx: scaleMPx,
      bleMin: bleMin,
      bleMax: bleMax,
      noSignal: noSignal,
      k: k,
      xTrain: xTrain,
      yTrain: yTrain,
      gaussLocs: gaussLocs,
    );
  }

  // ── Public API ──────────────────────────────────────────────────────

  /// Main prediction method.
  ///
  /// [scan] maps beacon ID → list of RSSI readings (dBm).
  ///        e.g. {'IW25031324': [-85.0, -88.0, -91.0], 'IW25030978': [-92.0]}
  ///
  /// Readings outside [-100, -40] dBm are automatically discarded.
  /// Missing beacons are filled with NO_SIGNAL (-100 dBm).
  ///
  /// Returns a [LocalizationResult] with both WKNN and Gaussian estimates
  /// fused into a single best prediction.
  LocalizationResult predict(Map<String, List<double>> scan) {
    final vec = _buildFeatureVector(scan);
    final wknnPred = _wknnPredict(vec);
    final gaussResult = _gaussianPredict(vec);

    // Use WKNN as primary; Gaussian for confidence + top candidates
    final predX = wknnPred[0];
    final predY = wknnPred[1];

    // Find nearest named reference zone
    String nearestZone = '';
    double nearestDist = double.infinity;
    int nearestFloor = 0;
    _gaussLocs.forEach((label, loc) {
      final d = sqrt(pow(predX - loc.x, 2) + pow(predY - loc.y, 2));
      if (d < nearestDist) {
        nearestDist = d;
        nearestZone = label;
        nearestFloor = loc.floor;
      }
    });

    return LocalizationResult(
      x: predX,
      y: predY,
      floor: nearestFloor,
      xMetres: predX * _scaleMPx,
      yMetres: predY * _scaleMPx,
      nearestZone: nearestZone,
      nearestZoneDistM: nearestDist * _scaleMPx,
      confidence: gaussResult.topConfidence,
      topCandidates: gaussResult.candidates,
    );
  }

  /// Convenience: pass raw scan as Map<beaconId, singleRSSI>
  /// (pre-averaged values from BLE scanner)
  LocalizationResult predictFromMeans(Map<String, double> means) {
    final scan = means.map((k, v) => MapEntry(k, [v]));
    return predict(scan);
  }

  // ── Feature vector ──────────────────────────────────────────────────

  List<double> _buildFeatureVector(Map<String, List<double>> scan) {
    return _beaconIds.map((beacon) {
      final readings = scan[beacon];
      if (readings == null || readings.isEmpty) return _noSignal;
      final clean = readings
          .where((v) => v >= _bleMin && v <= _bleMax)
          .toList();
      if (clean.isEmpty) return _noSignal;
      return _trimmedMean(clean);
    }).toList();
  }

  double _trimmedMean(List<double> vals) {
    if (vals.length <= 3) {
      return vals.reduce((a, b) => a + b) / vals.length;
    }
    final sorted = List<double>.from(vals)..sort();
    final trim = (vals.length * 0.1).round().clamp(1, vals.length ~/ 3);
    final trimmed = sorted.sublist(trim, sorted.length - trim);
    return trimmed.reduce((a, b) => a + b) / trimmed.length;
  }

  // ── WKNN ─────────────────────────────────────────────────────────────

  List<double> _wknnPredict(List<double> vec) {
    final distances = List<double>.generate(_xTrain.length, (i) {
      double sum = 0;
      for (int j = 0; j < vec.length; j++) {
        final diff = vec[j] - _xTrain[i][j];
        sum += diff * diff;
      }
      return sqrt(sum);
    });

    // Get top-k indices sorted by distance
    final indices = List<int>.generate(_xTrain.length, (i) => i)
      ..sort((a, b) => distances[a].compareTo(distances[b]));
    final topK = indices.take(_k).toList();

    // Weighted centroid
    final weights = topK.map((i) => 1.0 / (distances[i] + 1e-9)).toList();
    final sumW = weights.reduce((a, b) => a + b);

    double px = 0, py = 0;
    for (int i = 0; i < topK.length; i++) {
      px += (weights[i] / sumW) * _yTrain[topK[i]][0];
      py += (weights[i] / sumW) * _yTrain[topK[i]][1];
    }
    return [px, py];
  }

  // ── Gaussian fingerprint ─────────────────────────────────────────────

  _GaussResult _gaussianPredict(List<double> vec) {
    final scores = <String, double>{};

    _gaussLocs.forEach((label, loc) {
      double ll = 0.0;
      for (int i = 0; i < _beaconIds.length; i++) {
        final beacon = _beaconIds[i];
        final v = vec[i];
        final params = loc.beacons[beacon];
        if (params == null) {
          if (v > _noSignal + 1) ll += log(1e-9);
        } else {
          if (v > _noSignal + 1) {
            ll += _gaussianLogPdf(v, params.mu, params.sigma);
          } else if (params.mu > -85) {
            ll -= 2.0; // penalty for expected-but-absent beacon
          }
        }
      }
      scores[label] = ll;
    });

    // Softmax over top-5
    final sorted = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top5 = sorted.take(5).toList();
    final maxLL = top5.first.value;
    final expScores = top5.map((e) => exp(e.value - maxLL)).toList();
    final sumExp = expScores.reduce((a, b) => a + b);
    final probs = expScores.map((e) => e / sumExp).toList();

    final candidates = List.generate(top5.length, (i) {
      final loc = _gaussLocs[top5[i].key]!;
      return ZoneCandidate(
        label: top5[i].key,
        x: loc.x,
        y: loc.y,
        floor: loc.floor,
        probability: probs[i],
      );
    });

    return _GaussResult(topConfidence: probs[0], candidates: candidates);
  }

  /// Standard Gaussian log PDF: log(N(x; mu, sigma))
  double _gaussianLogPdf(double x, double mu, double sigma) {
    final z = (x - mu) / sigma;
    return -0.5 * z * z - log(sigma) - 0.9189385332; // log(sqrt(2*pi))
  }
}

// ── Internal data classes ─────────────────────────────────────────────

class _GaussParam {
  final double mu;
  final double sigma;
  const _GaussParam({required this.mu, required this.sigma});
}

class _GaussLoc {
  final double x;
  final double y;
  final int floor;
  final Map<String, _GaussParam> beacons;
  const _GaussLoc(
      {required this.x,
      required this.y,
      required this.floor,
      required this.beacons});
}

class _GaussResult {
  final double topConfidence;
  final List<ZoneCandidate> candidates;
  const _GaussResult({required this.topConfidence, required this.candidates});
}
