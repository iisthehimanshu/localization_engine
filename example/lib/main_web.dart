/// Web entry point for the localization engine, built to run inside the host
/// app's WebView.
///
/// The default entry point drives [LocalizationBackgroundService], which needs
/// a background isolate and has no web implementation — so this is a separate
/// `main` rather than a branch inside that one.
///
/// It answers two questions independently, because they fail for different
/// reasons:
///
///   1. Is scan data arriving from the host app at all? Answered by driving
///      [ScanSource] directly, with no network involved.
///   2. Does the full engine run on top of it? Answered by starting a real
///      [LocalizationEngine], which additionally needs the venue's beacon map
///      from the backend.
///
/// Keeping them apart means a backend problem cannot be mistaken for a broken
/// bridge.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localization_engine/localization_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BridgeProbeApp());
}

class BridgeProbeApp extends StatelessWidget {
  const BridgeProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Scan bridge probe',
      theme: ThemeData.dark(useMaterial3: true),
      home: const BridgeProbePage(),
    );
  }
}

class BridgeProbePage extends StatefulWidget {
  const BridgeProbePage({super.key});

  @override
  State<BridgeProbePage> createState() => _BridgeProbePageState();
}

class _BridgeProbePageState extends State<BridgeProbePage> {
  ScanSource? _source;
  String _sourceName = 'resolving…';
  String _readiness = '—';

  int _batches = 0;
  int _readings = 0;
  int _beacons = 0;
  final Set<String> _devices = <String>{};
  final Set<String> _iwDevices = <String>{};
  String _strongest = '—';
  String _gps = '—';
  String _heading = '—';
  String _lastError = '—';

  DateTime? _firstBatchAt;

  String _engineStatus = 'not started';
  LocalizationEngine? _engine;
  StreamSubscription<Map<String, dynamic>>? _engineLocationSub;
  String _engineLocation = '—';

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    // Resolves to the host bridge inside the WebView, or browser geolocation
    // in a plain browser.
    final source = await resolveScanSource();
    if (!mounted) return;
    setState(() {
      _source = source;
      _sourceName = source.description;
    });

    final readiness = await source.prepare(ble: true, gps: true);
    if (!mounted) return;
    setState(() {
      _readiness = readiness.isReady
          ? 'ready'
          : '${readiness.permissionDenied ? "denied" : "unavailable"}: '
              '${readiness.message}';
    });

    source.adapterChanges.listen((state) {
      if (!mounted) return;
      setState(() => _readiness = state.isReady ? 'ready' : '${state.message}');
    });

    source.bleBatches.listen((batch) {
      if (!mounted) return;
      setState(() {
        _firstBatchAt ??= DateTime.now();
        _batches++;
        _readings += batch.length;
        Map<String, dynamic>? best;
        num bestRssi = -1000;
        for (final reading in batch) {
          final device = reading['device']?.toString() ?? '';
          if (device.isNotEmpty) _devices.add(device);

          // The engine's own filter, applied here so the probe reports what
          // the engine would actually consider a beacon.
          final name = reading['name'];
          if (name is String && name.toLowerCase().startsWith('iw')) {
            _iwDevices.add(name);
          }
          final rssi = reading['rssi'];
          if (rssi is num && rssi > bestRssi) {
            bestRssi = rssi;
            best = reading;
          }
        }
        _beacons = _iwDevices.length;
        final strongest = best;
        if (strongest != null) {
          final name = strongest['name'] as String?;
          final label = (name != null && name.isNotEmpty)
              ? name
              : strongest['device'];
          _strongest = '$label  ${strongest['rssi']} dBm';
        }
      });
    });

    source.gpsFixes.listen((fix) {
      if (!mounted) return;
      final lat = (fix['latitude'] as num?)?.toStringAsFixed(5);
      final lon = (fix['longitude'] as num?)?.toStringAsFixed(5);
      final acc = (fix['accuracy'] as num?)?.round();
      setState(() => _gps = '$lat, $lon  (±${acc}m)');
    });

    source.headings.listen((heading) {
      if (!mounted) return;
      setState(() => _heading = '${heading.round()}°');
    });

    const config = ScanSessionConfig(
      venueName: 'Iwayplus',
      baseUrl: 'https://dev.iwayplus.in',
      mode: 'bothGPSandBLE',
    );

    try {
      await source.startGps(config);
    } catch (error) {
      if (mounted) setState(() => _lastError = 'gps: $error');
    }
    try {
      await source.startBle(config);
    } catch (error) {
      if (mounted) setState(() => _lastError = 'ble: $error');
    }
  }

  /// Starts the real engine on top of the same source.
  ///
  /// Separate from the probe above because this one also talks to the backend
  /// for the venue's beacon map, and that is a different failure mode.
  Future<void> _startEngine() async {
    setState(() => _engineStatus = 'starting…');
    try {
      final engine = LocalizationEngine(
        'Iwayplus',
        baseURL: 'https://dev.iwayplus.in',
      );
      _engine = engine;
      _engineLocationSub = engine.userLocation.listen((location) {
        if (!mounted) return;
        setState(() => _engineLocation = location.toString());
      });
      setState(() => _engineStatus = 'running');
    } catch (error) {
      setState(() => _engineStatus = 'failed: $error');
    }
  }

  @override
  void dispose() {
    unawaited(_engineLocationSub?.cancel());
    unawaited(_engine?.dispose());
    unawaited(_source?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _firstBatchAt == null
        ? null
        : DateTime.now().difference(_firstBatchAt!).inSeconds;
    final rate = (elapsed != null && elapsed > 0)
        ? (_readings / elapsed).round().toString()
        : '—';

    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _Heading('scan source'),
            _Row('source', _sourceName),
            _Row('adapters', _readiness, bad: !_readiness.startsWith('ready')),
            const _Heading('ble from host'),
            _Row('batches', '$_batches'),
            _Row('readings', '$_readings'),
            _Row('readings/sec', rate),
            _Row('unique devices', '${_devices.length}'),
            _Row('iw* beacons', '$_beacons'),
            _Row('strongest', _strongest),
            const _Heading('other streams'),
            _Row('gps', _gps),
            _Row('heading', _heading),
            _Row('last error', _lastError, bad: _lastError != '—'),
            const _Heading('full engine'),
            _Row('status', _engineStatus),
            _Row('location', _engineLocation),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _engine == null ? _startEngine : null,
              child: const Text('start LocalizationEngine'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF7DD3FC),
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.bad = false});
  final String label;
  final String value;
  final bool bad;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF1E293B))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: Color(0xFF94A3B8))),
            ),
            Expanded(
              flex: 2,
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: bad ? const Color(0xFFFCA5A5) : Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}
