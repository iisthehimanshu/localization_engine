import 'package:flutter/foundation.dart';

import 'bridge_scan_source_web.dart';
import 'browser_geolocation_scan_source.dart';
import 'scan_source.dart';

/// Picks the best source available to a web build.
///
/// Inside the host app's WebView the bridge provides BLE, GPS and heading. In
/// a plain browser there is no bridge and only geolocation is possible — the
/// same bundle serves both rather than shipping two.
Future<ScanSource> resolveScanSource() async {
  final bridge = await BridgeScanSource.connect();
  if (bridge != null) return bridge;

  debugPrint('Running without a host app; falling back to browser geolocation.');
  return BrowserGeolocationScanSource();
}
