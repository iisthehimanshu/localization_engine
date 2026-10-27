import 'dart:async';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:localization_engine/localization_engine.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScanLoggerApp());
}

class ScanLoggerApp extends StatelessWidget {
  const ScanLoggerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Scan logger',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const ScanLoggerPage(),
    );
  }
}

class ScanLoggerPage extends StatefulWidget {
  const ScanLoggerPage({super.key});

  @override
  State<ScanLoggerPage> createState() => _ScanLoggerPageState();
}

class _ScanLoggerPageState extends State<ScanLoggerPage> {
  /// Android allows only a handful of Wi-Fi scans per two minutes (unless
  /// "Wi-Fi scan throttling" is turned off in developer options), so asking
  /// every second is as fast as the platform will go: throttled requests fail
  /// cheaply and the next allowed one is picked up within a second.
  static const _wifiScanRequestInterval = Duration(seconds: 1);

  final _recorder = CsvScanRecorder();

  ScanSource? _source;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Timer? _wifiTimer;

  bool _isScanning = false;
  bool _isBusy = false;
  String? _status;
  String? _savedPath;

  @override
  void initState() {
    super.initState();
    // Offer the previous session's file for sharing after an app restart.
    unawaited(CsvScanRecorder.latestSavedFile().then((path) {
      if (mounted && path != null) setState(() => _savedPath ??= path);
    }));
  }

  @override
  void dispose() {
    unawaited(_stopScanning(save: false));
    super.dispose();
  }

  Future<void> _startScanning() async {
    setState(() {
      _isBusy = true;
      _status = null;
    });
    try {
      // A fresh source per session: the native side ends the BLE stream when
      // scanning stops, so a previous source's stream cannot be reused.
      final source = await resolveScanSource();
      final readiness = await source.prepare(ble: true, gps: true);
      if (!readiness.isReady) {
        await source.dispose();
        throw StateError(readiness.message ?? 'Bluetooth or GPS unavailable.');
      }
      _source = source;

      await _recorder.open();

      // Listen before starting so the native stream handlers are attached by
      // the time the first results arrive.
      _subscriptions
        ..add(source.bleBatches.listen(_recorder.addBleBatch,
            onError: _onStreamError))
        ..add(source.gpsFixes.listen(_recorder.addGpsFix,
            onError: _onStreamError));

      const config = ScanSessionConfig(
        venueName: 'scan-logger',
        baseUrl: '',
        mode: 'bothGPSandBLE',
      );
      await source.startBle(config);
      await source.startGps(config);

      await _startWifi();

      setState(() => _isScanning = true);
    } catch (error) {
      await _stopScanning(save: false);
      if (mounted) setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _startWifi() async {
    final can = await WiFiScan.instance.canStartScan(askPermissions: true);
    if (can != CanStartScan.yes) {
      // Not fatal: iOS has no Wi-Fi scanning API at all, and BLE + GPS are
      // still worth recording without it.
      setState(() => _status = 'Wi-Fi scanning unavailable ($can).');
      return;
    }
    _subscriptions.add(WiFiScan.instance.onScannedResultsAvailable
        .listen(_recorder.addWifiResults, onError: _onStreamError));
    unawaited(WiFiScan.instance.startScan());
    _wifiTimer = Timer.periodic(
      _wifiScanRequestInterval,
      (_) => unawaited(WiFiScan.instance.startScan()),
    );
  }

  Future<void> _shareSavedFile() async {
    final path = _savedPath;
    if (path == null) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path, mimeType: 'text/csv')]),
    );
  }

  void _onStreamError(Object error) {
    if (mounted) setState(() => _status = error.toString());
  }

  Future<void> _stopScanning({bool save = true}) async {
    if (save && mounted) setState(() => _isBusy = true);

    _wifiTimer?.cancel();
    _wifiTimer = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    final source = _source;
    _source = null;
    if (source != null) {
      await source.stopBle();
      await source.stopGps();
      await source.dispose();
    }

    final path = await _recorder.close();

    if (!mounted) return;
    setState(() {
      _isScanning = false;
      _isBusy = false;
      if (save) _savedPath = path;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Scan logger')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _recorder,
          builder: (context, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _isScanning || _isBusy ? null : _startScanning,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start scanning'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed:
                          _isScanning && !_isBusy ? _stopScanning : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop scanning'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _CountTile(
                icon: Icons.bluetooth_searching,
                label: 'BLE advertisements',
                count: _recorder.bleCount,
              ),
              _CountTile(
                icon: Icons.gps_fixed,
                label: 'GPS fixes',
                count: _recorder.gpsCount,
              ),
              _CountTile(
                icon: Icons.wifi,
                label: 'Wi-Fi access point readings',
                count: _recorder.wifiCount,
              ),
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(_status!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              if (_savedPath != null) ...[
                const SizedBox(height: 16),
                Text('Last saved file', style: theme.textTheme.labelLarge),
                SelectableText(_savedPath!),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _isScanning ? null : _shareSavedFile,
                  icon: const Icon(Icons.share),
                  label: const Text('Share last saved file'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.icon,
    required this.label,
    required this.count,
  });

  final IconData icon;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: Text(
        '$count',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }
}

/// Streams every BLE, GPS and Wi-Fi reading of a session into one CSV file.
///
/// Rows are written as they arrive rather than held until stop: a busy venue
/// produces hundreds of BLE advertisements a second, which would otherwise
/// pile up in memory for the whole session.
class CsvScanRecorder extends ChangeNotifier {
  static const _header = [
    'timestamp_ms',
    'time_iso',
    'source',
    'id',
    'name',
    'rssi',
    'frequency_mhz',
    'latitude',
    'longitude',
    'accuracy_m',
    'altitude_m',
    'speed_mps',
    'bearing_deg',
    'extra',
  ];

  static const _converter = ListToCsvConverter(eol: '\n');

  IOSink? _sink;
  String? _path;

  /// Wi-Fi results include access points cached from earlier scans; only a
  /// changed (bssid, timestamp) pair is a new sighting.
  final _seenWifi = <String>{};

  int bleCount = 0;
  int gpsCount = 0;
  int wifiCount = 0;

  static Future<Directory> _directory() async =>
      (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
      await getApplicationDocumentsDirectory();

  /// The most recently written session file, if any.
  static Future<String?> latestSavedFile() async {
    final files = (await _directory())
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.csv'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files.isEmpty ? null : files.first.path;
  }

  Future<void> open() async {
    final directory = await _directory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final file = File('${directory.path}/scan_$stamp.csv');

    _path = file.path;
    _sink = file.openWrite()..write('${_converter.convert([_header])}\n');
    _seenWifi.clear();
    bleCount = gpsCount = wifiCount = 0;
    notifyListeners();
  }

  /// Flushes and closes the file, returning its path.
  Future<String?> close() async {
    final sink = _sink;
    _sink = null;
    if (sink == null) return null;
    await sink.flush();
    await sink.close();
    return _path;
  }

  void addBleBatch(List<Map<String, dynamic>> batch) {
    _write([
      for (final reading in batch)
        _row(
          time: _parseTime(reading['timestamp']),
          source: 'ble',
          id: reading['device'],
          name: reading['name'],
          rssi: reading['rssi'],
          extra: reading['manufacturerHex'],
        ),
    ]);
    bleCount += batch.length;
    notifyListeners();
  }

  void addGpsFix(Map<String, dynamic> fix) {
    _write([
      _row(
        time: _parseTime(fix['timestamp']),
        source: 'gps',
        latitude: fix['latitude'],
        longitude: fix['longitude'],
        accuracy: fix['accuracy'],
        altitude: fix['altitude'],
        speed: fix['speed'],
        bearing: fix['bearing'],
      ),
    ]);
    gpsCount++;
    notifyListeners();
  }

  void addWifiResults(List<WiFiAccessPoint> accessPoints) {
    final now = DateTime.now();
    final fresh = accessPoints
        .where((ap) => _seenWifi.add('${ap.bssid}|${ap.timestamp}'))
        .toList();
    if (fresh.isEmpty) return;
    _write([
      for (final ap in fresh)
        _row(
          time: now,
          source: 'wifi',
          id: ap.bssid,
          name: ap.ssid,
          rssi: ap.level,
          frequency: ap.frequency,
          extra: 'boot_us=${ap.timestamp}',
        ),
    ]);
    wifiCount += fresh.length;
    notifyListeners();
  }

  void _write(List<List<Object?>> rows) {
    final sink = _sink;
    if (sink == null || rows.isEmpty) return;
    final cells = [
      for (final row in rows) [for (final cell in row) cell ?? ''],
    ];
    sink.write('${_converter.convert(cells)}\n');
  }

  List<Object?> _row({
    required DateTime time,
    required String source,
    Object? id,
    Object? name,
    Object? rssi,
    Object? frequency,
    Object? latitude,
    Object? longitude,
    Object? accuracy,
    Object? altitude,
    Object? speed,
    Object? bearing,
    Object? extra,
  }) =>
      [
        time.millisecondsSinceEpoch,
        time.toIso8601String(),
        source,
        id,
        name,
        rssi,
        frequency,
        latitude,
        longitude,
        accuracy,
        altitude,
        speed,
        bearing,
        extra,
      ];

  /// Android sends epoch millis; older iOS builds send an ISO-8601 string.
  static DateTime _parseTime(Object? raw) {
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    if (raw is String) return DateTime.tryParse(raw) ?? DateTime.now();
    return DateTime.now();
  }
}
