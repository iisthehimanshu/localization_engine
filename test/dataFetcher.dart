import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:localization_engine/initialLocalization.dart';
import 'package:localization_engine/nearest_beacon_resolver.dart';
import 'package:localization_engine/src/network/api/localizationUsingMLModelapi.dart';
import 'package:localization_engine/src/network/model/beaconData.dart';

import 'ble_localizer.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Data model matching the CSV row structure
// ─────────────────────────────────────────────────────────────────────────────

class BleEntry {
  final String device;
  final String name;
  final int rssi;
  final DateTime timestamp;

  const BleEntry({
    required this.device,
    required this.name,
    required this.rssi,
    required this.timestamp,
  });

  factory BleEntry.fromMap(Map<String, dynamic> map) {
    return BleEntry(
      device: map['device'] as String,
      name: map['name'] as String,
      rssi: int.parse(map['rssi'].toString()),
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Core function
//
// Step 1 — Split rows into ordered sub-lists where each sub-list spans
//           no more than 6 seconds (measured from the first row's timestamp
//           in that sub-list to the last row's timestamp).
//
// Step 2 — Convert each sub-list into:
//           Map<String, List<MapEntry<DateTime, int>>>
//           key   → device name  (String)
//           value → ordered list of (timestamp, rssi) pairs
//
// Step 3 — Return the list of converted maps.
// ─────────────────────────────────────────────────────────────────────────────

List<Map<String, List<MapEntry<DateTime, int>>>> convertAll(
    List<BleEntry> entries,
    ) {
  if (entries.isEmpty) return [];

  return [_chunkToMap(entries)];
}

List<Map<String, List<MapEntry<DateTime, int>>>> splitAndConvert(
    List<BleEntry> entries, {
      Duration maxDuration = const Duration(seconds: 6),
    }) {
  if (entries.isEmpty) return [];

  // ── Step 1: split into chunks ─────────────────────────────────────────────
  final List<List<BleEntry>> chunks = [];
  List<BleEntry> currentChunk = [];
  DateTime? chunkStart;

  for (final entry in entries) {
    if (currentChunk.isEmpty) {
      // Start a fresh chunk
      currentChunk = [entry];
      chunkStart = entry.timestamp;
    } else {
      final elapsed = entry.timestamp.difference(chunkStart!);
      if (elapsed > maxDuration) {
        // Current entry would push the chunk beyond 6 s → seal it
        chunks.add(currentChunk);
        currentChunk = [entry];
        chunkStart = entry.timestamp;
      } else {
        currentChunk.add(entry);
      }
    }
  }

  // Don't forget the last open chunk
  if (currentChunk.isNotEmpty) chunks.add(currentChunk);

  // ── Step 2 & 3: convert each chunk and collect ────────────────────────────
  return chunks.map(_chunkToMap).toList();
}

List<Map<String, List<MapEntry<DateTime, int>>>> rollingSplitAndConvertTimeBased(
    List<BleEntry> entries, {
      Duration maxDuration = const Duration(seconds: 6),
      Duration step = const Duration(seconds: 1),
    }) {
  if (entries.isEmpty) return [];

  // Ensure sorted by timestamp
  entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));

  final List<List<BleEntry>> chunks = [];

  int startPtr = 0;
  int endPtr = 0;

  DateTime windowStart = entries.first.timestamp;
  final DateTime lastTime = entries.last.timestamp;

  while (windowStart.isBefore(lastTime) || windowStart.isAtSameMomentAs(lastTime)) {
    final windowEnd = windowStart.add(maxDuration);

    // Move startPtr to first element >= windowStart
    while (startPtr < entries.length &&
        entries[startPtr].timestamp.isBefore(windowStart)) {
      startPtr++;
    }

    // Move endPtr to last element <= windowEnd
    while (endPtr < entries.length &&
        !entries[endPtr].timestamp.isAfter(windowEnd)) {
      endPtr++;
    }

    if (startPtr < endPtr) {
      chunks.add(entries.sublist(startPtr, endPtr));
    }

    // Slide window by 1 second
    windowStart = windowStart.add(step);
  }

  return chunks.map(_chunkToMap).toList();
}

/// Converts a flat list of [BleEntry] into
/// `Map<String, List<MapEntry<DateTime, int>>>`.
///
/// Key   → device name
/// Value → list of MapEntry(timestamp, rssi), preserving original order
Map<String, List<MapEntry<DateTime, int>>> _chunkToMap(List<BleEntry> chunk) {
  final Map<String, List<MapEntry<DateTime, int>>> result = {};

  for (final entry in chunk) {
    result
        .putIfAbsent(entry.name, () => [])
        .add(MapEntry(entry.timestamp, entry.rssi));
  }

  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// CSV loader
//
// Reads the file at [csvPath], parses the header row to build a column index,
// then maps every subsequent line to a BleEntry.
// ─────────────────────────────────────────────────────────────────────────────

Future<List<dynamic>> extractResponseBody(String path) async {
  final file = File(path);
  final contents = await file.readAsString();

  final data = jsonDecode(contents);

  if (data is List<dynamic>) {
    return data;
  } else {
    throw Exception("JSON is not a List");
  }
}

List<BleEntry> loadCsv(String csvPath) {
  final file = File(csvPath);
  if (!file.existsSync()) {
    throw FileSystemException('CSV file not found', csvPath);
  }

  final lines = file.readAsLinesSync();
  if (lines.length < 2) return []; // header-only or empty file

  // Build a column-name → index map from the header
  final headers = lines.first.split(',');
  final idx = {for (int i = 0; i < headers.length; i++) headers[i].trim(): i};

  // Required columns
  for (final col in ['device', 'name', 'rssi', 'timestamp']) {
    if (!idx.containsKey(col)) {
      throw FormatException('Missing required column "$col" in CSV header');
    }
  }

  return lines.skip(1).where((l) => l.trim().isNotEmpty).map((line) {
    // Split on commas but respect quoted fields (e.g. "value,with,commas")
    final cols = _splitCsvLine(line);
    return BleEntry.fromMap({
      'device'   : cols[idx['device']!],
      'name'     : cols[idx['name']!],
      'rssi'     : cols[idx['rssi']!],
      'timestamp': cols[idx['timestamp']!],
    });
  }).toList();
}

/// Minimal RFC-4180-compatible CSV line splitter.
/// Handles double-quoted fields that may contain commas.
List<String> _splitCsvLine(String line) {
  final fields = <String>[];
  final buffer = StringBuffer();
  bool inQuotes = false;

  for (int i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      // Escaped quote inside a quoted field ("" → ")
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++; // skip the second quote
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch == ',' && !inQuotes) {
      fields.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  fields.add(buffer.toString().trim());
  return fields;
}

// ─────────────────────────────────────────────────────────────────────────────
// Entry point — pass the CSV path as a command-line argument, or edit the
// default path below.
//
//   dart ble_data_splitter.dart /path/to/towards_entry.csv
// ─────────────────────────────────────────────────────────────────────────────

double calculateDistance(List<int> gt, int x, int y) {
  return sqrt(pow(gt[0] - x, 2) + pow(gt[1] - y, 2));
}


// Future<void> main() async {
//   final csvPath = 'test/floor_0/107_344_0.csv';
//
//   print('Loading CSV from: $csvPath');
//   final entries = loadCsv(csvPath);
//   print('Loaded ${entries.length} entries.\n');
//
//   // final result = splitAndConvert(entries);
//   final result = rollingSplitAndConvertTimeBased(entries);
//   // final result = convertAll(entries);
//
//   print('Total chunks: ${result.length}');
//
//   final resolver = NearestBeaconResolver(InitialLocalization("Testing"));
//
//   Map<String, dynamic> apiBeaconMap = {};
//   List<dynamic> responseBody = await extractResponseBody("test/response.json");
//   List<dynamic> beaconList = responseBody.map((data) => Beacon.fromJson(data)).toList();
//   for (var beacon in beaconList) {
//     if (beacon.name != null) {
//       apiBeaconMap[beacon.name!] = beacon;
//     }
//   }
//
//   List<int> groundTruth = [120,313];
//
//   for (int i = 0; i < result.length; i++) {
//     final chunk = result[i];
//     final resolved = resolver.resolve(chunk, apiBeaconMap: apiBeaconMap);
//     if(resolved != null){
//       final int x = resolved.x;
//       final int y = resolved.y;
//
//       final distance = calculateDistance(groundTruth, x, y) * 0.3;
//
//       print('$i\t${x.toStringAsFixed(2)}\t\t${y.toStringAsFixed(2)}\t\t${distance.toStringAsFixed(2)} m');
//       print("\n");
//     }
//   }
// }

Future<void> main() async {
  final dirPath = 'test/floor_0';
  final dir = Directory(dirPath);

  if (!dir.existsSync()) {
    print('Directory not found: $dirPath');
    return;
  }

  final resolver = NearestBeaconResolver(InitialLocalization("Testing"));

  final localizer = await BLELocalizer.fromAsset('test/ble_model.json');

  // Load beacon map once
  Map<String, dynamic> apiBeaconMap = {};
  List<dynamic> responseBody = await extractResponseBody("test/response.json");
  List<dynamic> beaconList =
  responseBody.map((data) => Beacon.fromJson(data)).toList();

  for (var beacon in beaconList) {
    if (beacon.name != null) {
      apiBeaconMap[beacon.name!] = beacon;
    }
  }

  final files = dir
      .listSync()
      .where((f) => f is File && f.path.endsWith('.csv'))
      .cast<File>();

  for (final file in files) {
    final fileName = file.uri.pathSegments.last;

    // ── Extract ground truth from filename ──
    final nameWithoutExt = fileName.replaceAll('.csv', '');
    final parts = nameWithoutExt.split('_');

    if (parts.length < 2) {
      print('Skipping invalid filename: $fileName');
      continue;
    }

    final int gtX = int.tryParse(parts[0]) ?? 0;
    final int gtY = int.tryParse(parts[1]) ?? 0;
    final groundTruth = [gtX, gtY];

    print('\n📂 Processing: $fileName (GT: $gtX, $gtY)');

    // ── Load CSV ──
    final entries = loadCsv(file.path);

    // Use your non-splitting version
    final result = convertAll(entries);

    for (int i = 0; i < result.length; i++) {
      final chunk = result[i];
      final localizerResult = localizer.predict(chunk.map(
            (beaconId, entries) => MapEntry(
          beaconId,
          entries.map((e) => e.value.toDouble()).toList(),
        ),
      ));
      var loc = localizerResult.nearestZone.split("_");
      final gtX = int.parse(loc[0]);
      final gtY = int.parse(loc[1]);
      final distance = calculateDistance(groundTruth, gtX, gtY) * 0.3;
      final top = localizerResult.topCandidates[0];

      print('''
╔══════════════════════════════════════╗
║         BLE LOCALIZATION RESULT      ║
╠══════════════════════════════════════╣
║ Ground Truth : $groundTruth
║ Nearest Zone : ${localizerResult.nearestZone}
║ Distance     : ${distance.toStringAsFixed(2)} m
║ Confidence   : ${(localizerResult.confidence * 100).toStringAsFixed(1)}%
╠══════════════════════════════════════╣
║ Top Candidate
${top.toStringWithGroundTruth(groundTruth[0], groundTruth[1], 0.3)}
╚══════════════════════════════════════╝
'''); // best match
      continue;
      final resolved = await resolver.resolve(chunk, apiBeaconMap: apiBeaconMap);

      if (resolved != null) {
        final int x = resolved.x;
        final int y = resolved.y;

        final int tempX = resolved.tempX!;
        final int tempY = resolved.tempY!;

        final distance =
            calculateDistance(groundTruth, x, y) * 0.3;

        final distance2 =
            calculateDistance(groundTruth, tempX, tempY) * 0.3;

        print(
            '\n$fileName\t$x\t$y\t${distance.toStringAsFixed(2)} m');
        print(
            '\n$fileName\t$tempX\t$tempY\t${distance2.toStringAsFixed(2)} m');
      }
    }
  }
}