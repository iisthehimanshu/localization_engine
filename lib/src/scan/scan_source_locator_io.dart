import 'platform_channel_scan_source.dart';
import 'scan_source.dart';

/// Native hosts always talk to the plugin.
Future<ScanSource> resolveScanSource() async => PlatformChannelScanSource();
