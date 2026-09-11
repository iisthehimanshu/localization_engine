import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../config/config.dart';

/// Uploads queued tracking payloads through the bulk location API.
class TrackingBulkApi {
  /// Records per request, sized to stay well under common JSON body limits
  /// (Express defaults to 100 KB).
  static const maxBatch = 200;

  static const _timeout = Duration(seconds: 30);

  /// Posts [payloads] (as produced by `TrackingPayload.toJson`) and returns
  /// whether the server accepted them.
  static Future<bool> upload(List<Map<String, dynamic>> payloads) async {
    final url =
        '${AppConfig.baseUrl}/admin/update-locations-bulk?api_key=${AppConfig.apiKey}';
    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'trackingRecords': payloads.map(toRecord).toList(),
            }),
          )
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) return true;
      print('[TrackingBulkApi] response.statusCode : ${response.statusCode} - ${response.body}');
    } catch (e) {
      print('[TrackingBulkApi] ⚠️ Upload failed: $e');
    }
    return false;
  }

  /// Maps a websocket tracking payload to a `trackingRecords` entry.
  ///
  /// Uses the beacon point when present, else the GPS point. lat/lon keep the
  /// payload's dot-stripped integer form; the server parses them.
  static Map<String, dynamic> toRecord(Map<String, dynamic> payload) {
    final pts = payload['pts'] as Map<String, dynamic>? ?? const {};
    final nb = pts['nb'] as List?;
    final haveBeacon = nb?.isNotEmpty ?? false;
    final List point = haveBeacon ? nb! : (pts['gp'] as List? ?? const []);

    dynamic at(int i) => i < point.length ? point[i] : null;
    int intAt(int i) {
      final value = at(i);
      return value is num ? value.round() : 0;
    }

    return {
      'device_id': payload['id'],
      'ts_ms': payload['t'],
      'x': intAt(0),
      'y': intAt(1),
      'lat': at(2),
      'lon': at(3),
      'haveGps': !haveBeacon,
      'conf': '',
      'motion': '',
      'b1': '',
      'b1_rssi': 0,
      'n': 0,
      'floor': intAt(4),
    };
  }
}
