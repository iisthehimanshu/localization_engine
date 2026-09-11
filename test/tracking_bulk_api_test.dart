import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/src/network/api/UserTrackingWebSocket.dart';
import 'package:localization_engine/src/network/api/tracking_bulk_api.dart';

Map<String, dynamic> recordFor(Map<String, List<int?>> pts) =>
    TrackingBulkApi.toRecord(
      TrackingPayload(id: 'device-1', t: 1757570000000, pts: pts, venueName: 'venue')
          .toJson(),
    );

void main() {
  test('beacon point supplies coordinates and marks haveGps false', () {
    final record = recordFor({
      'nb': [423, 187, 286139, 772090, 2, 1],
      'gp': [null, null, 286140, 772091, 0, 2],
    });

    expect(record, {
      'device_id': 'device-1',
      'ts_ms': 1757570000000,
      'x': 423,
      'y': 187,
      'lat': 286139,
      'lon': 772090,
      'haveGps': false,
      'conf': '',
      'motion': '',
      'b1': '',
      'b1_rssi': 0,
      'n': 0,
      'floor': 2,
    });
  });

  test('GPS-only point has zero x/y and marks haveGps true', () {
    final record = recordFor({
      'gp': [null, null, 286140, 772091, 1, 2],
    });

    expect(record['x'], 0);
    expect(record['y'], 0);
    expect(record['lat'], 286140);
    expect(record['lon'], 772091);
    expect(record['floor'], 1);
    expect(record['haveGps'], true);
  });
}
