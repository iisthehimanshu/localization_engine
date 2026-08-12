import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localization_engine/localization_engine.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LocalizationHostApp());
}

class LocalizationHostApp extends StatelessWidget {
  const LocalizationHostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Localization host',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const LocalizationServicePage(),
    );
  }
}

class LocalizationServicePage extends StatefulWidget {
  const LocalizationServicePage({super.key});

  @override
  State<LocalizationServicePage> createState() =>
      _LocalizationServicePageState();
}

class _LocalizationServicePageState extends State<LocalizationServicePage> {
  final _venueController = TextEditingController(text: 'Iwayplus');
  final _baseUrlController = TextEditingController(
    text: 'https://dev.iwayplus.in',
  );
  final _durationController = TextEditingController(text: '30');

  LocalizationMode _selectedMode = LocalizationMode.bothGPSandBLE;
  LocalizationServiceConfiguration? _activeConfiguration;
  Duration? _remainingDuration;
  Timer? _refreshTimer;
  bool _isRunning = false;
  bool _isBusy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshServiceState());
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refreshServiceState(showBusy: false)),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _venueController.dispose();
    _baseUrlController.dispose();
    _durationController.dispose();
    super.dispose();
  }

  Future<void> _refreshServiceState({bool showBusy = true}) async {
    if (showBusy && mounted) setState(() => _isBusy = true);
    try {
      final running = await LocalizationBackgroundService.isRunning;
      final configuration =
          await LocalizationBackgroundService.activeConfiguration;
      final remaining = await LocalizationBackgroundService.remainingDuration;
      if (!mounted) return;
      setState(() {
        _isRunning = running;
        _activeConfiguration = configuration;
        _remainingDuration = remaining;
        if (configuration != null) _selectedMode = configuration.mode;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (showBusy && mounted) setState(() => _isBusy = false);
    }
  }

  Duration? _readDuration() {
    final value = _durationController.text.trim();
    if (value.isEmpty) return null;
    final minutes = int.tryParse(value);
    if (minutes == null || minutes <= 0) {
      throw const FormatException(
        'Enter positive minutes, or leave duration blank to run indefinitely.',
      );
    }
    return Duration(minutes: minutes);
  }

  Future<void> _startService() async {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      await LocalizationBackgroundService.start(
        venueName: _venueController.text,
        baseUrl: _baseUrlController.text.trim().isEmpty
            ? null
            : _baseUrlController.text.trim(),
        mode: _selectedMode,
        duration: _readDuration(),
      );
      await _refreshServiceState(showBusy: false);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _stopService() async {
    setState(() {
      _isBusy = true;
      _error = null;
    });
    try {
      await LocalizationBackgroundService.stop();
      await _refreshServiceState(showBusy: false);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  String get _statusText {
    if (!_isRunning) return 'Stopped';
    return 'Running · ${_modeLabel(_activeConfiguration?.mode ?? _selectedMode)}';
  }

  String? get _deadlineText {
    if (!_isRunning || _activeConfiguration?.stopAt == null) return null;
    final remaining = _remainingDuration ?? Duration.zero;
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    final seconds = remaining.inSeconds.remainder(60);
    return 'Stops in ${hours > 0 ? '${hours}h ' : ''}${minutes}m ${seconds}s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Localization host')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    Icon(
                      _isRunning
                          ? Icons.location_searching
                          : Icons.location_off,
                      color: _isRunning ? Colors.green : Colors.grey,
                      size: 34,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _statusText,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (_activeConfiguration != null)
                            Text(_activeConfiguration!.venueName),
                          if (_deadlineText != null) Text(_deadlineText!),
                        ],
                      ),
                    ),
                    if (_isBusy)
                      const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _venueController,
              enabled: !_isBusy,
              decoration: const InputDecoration(
                labelText: 'Venue name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _baseUrlController,
              enabled: !_isBusy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'Leave blank for package default',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _durationController,
              enabled: !_isBusy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Run duration (minutes)',
                hintText: 'Leave blank to run indefinitely',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            Text('Localization mode',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<LocalizationMode>(
              segments: const [
                ButtonSegment(
                  value: LocalizationMode.onlyGps,
                  icon: Icon(Icons.gps_fixed),
                  label: Text('GPS'),
                ),
                ButtonSegment(
                  value: LocalizationMode.onlyBle,
                  icon: Icon(Icons.bluetooth),
                  label: Text('BLE'),
                ),
                ButtonSegment(
                  value: LocalizationMode.bothGPSandBLE,
                  icon: Icon(Icons.explore),
                  label: Text('Both'),
                ),
              ],
              selected: {_selectedMode},
              onSelectionChanged: _isBusy
                  ? null
                  : (selection) =>
                      setState(() => _selectedMode = selection.single),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: _isBusy ? null : _startService,
              icon: const Icon(Icons.play_arrow),
              label: Text(_isRunning ? 'Restart service' : 'Start service'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _isBusy || !_isRunning ? null : _stopService,
              icon: const Icon(Icons.stop),
              label: const Text('Stop service'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _modeLabel(LocalizationMode mode) => switch (mode) {
      LocalizationMode.onlyGps => 'GPS',
      LocalizationMode.onlyBle => 'BLE',
      LocalizationMode.bothGPSandBLE => 'GPS + BLE',
    };
