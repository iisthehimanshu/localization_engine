import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:adapter_manager/adapter_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../localization_engine.dart' show LocalizationEngine;
import '../localization_mode.dart';
import 'localization_service_configuration.dart';

const _configurationKey = 'localization_background_service.configuration';
const _stopEvent = 'localization_background_service.stop';
const _notificationId = 4815;

LocalizationEngine? _backgroundEngine;
LocalizationEngine? _iosForegroundEngine;
Timer? _backgroundStopTimer;
bool _backgroundStopInProgress = false;
const _localizationMethodChannel = MethodChannel('localization_engine');

/// Owns the foreground-service lifecycle for background localization.
class LocalizationBackgroundService {
  LocalizationBackgroundService._();

  static Future<void> start({
    required String venueName,
    String? baseUrl,
    LocalizationMode mode = LocalizationMode.bothGPSandBLE,
    Duration? duration,
  }) async {
    final normalizedVenueName = venueName.trim();
    if (normalizedVenueName.isEmpty) {
      throw ArgumentError.value(venueName, 'venueName', 'Must not be empty.');
    }
    if (duration != null && duration <= Duration.zero) {
      throw ArgumentError.value(
        duration,
        'duration',
        'Must be greater than zero.',
      );
    }

    // Permission dialogs require the foreground host isolate.
    await prepareLocalizationAdapters(mode);

    if (await isRunning) {
      await stop();
    }

    final configuration = LocalizationServiceConfiguration(
      venueName: normalizedVenueName,
      baseUrl: baseUrl,
      mode: mode,
      stopAt: duration == null ? null : DateTime.now().add(duration),
    );
    await _writeConfiguration(configuration);

    if (Platform.isIOS) {
      _iosForegroundEngine = LocalizationEngine(
        configuration.venueName,
        baseURL: configuration.baseUrl,
        localizationMode: configuration.mode,
        skipAdapterSetup: true,
        stopAt: configuration.stopAt,
      );
      return;
    }

    final service = FlutterBackgroundService();
    final configured = await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: localizationBackgroundServiceOnStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        initialNotificationTitle: 'Localization active',
        initialNotificationContent: 'GPS and beacon localization is running',
        foregroundServiceNotificationId: _notificationId,
        foregroundServiceTypes: const <AndroidForegroundType>[
          AndroidForegroundType.location,
          AndroidForegroundType.connectedDevice,
        ],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: localizationBackgroundServiceOnStart,
        onBackground: localizationIosBackground,
      ),
    );
    if (!configured) {
      await _clearConfiguration();
      throw StateError(
        'Unable to configure the localization background service.',
      );
    }

    final started = await service.startService();
    if (!started) {
      await _clearConfiguration();
      throw StateError('Unable to start the localization background service.');
    }
  }

  static Future<void> stop() async {
    if (Platform.isIOS) {
      final engine = _iosForegroundEngine;
      _iosForegroundEngine = null;
      if (engine != null) {
        await engine.dispose();
      } else {
        try {
          await _localizationMethodChannel.invokeMethod<void>(
            'stopNativeSession',
          );
        } on MissingPluginException {
          // The plugin may not be registered during process teardown.
        }
      }
      await _clearConfiguration();
      return;
    }

    await _clearConfiguration();
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) return;

    service.invoke(_stopEvent);
    await _waitUntilStopped(service);
  }

  static Future<bool> get isRunning async {
    if (!Platform.isIOS) return FlutterBackgroundService().isRunning();
    final configuration = await activeConfiguration;
    return configuration != null;
  }

  static Future<LocalizationServiceConfiguration?>
      get activeConfiguration async {
    final configuration = await _readConfiguration();
    final stopAt = configuration?.stopAt;
    if (stopAt != null && stopAt.isBefore(DateTime.now())) {
      await _clearConfiguration();
      if (Platform.isIOS) {
        try {
          await _localizationMethodChannel.invokeMethod<void>(
            'stopNativeSession',
          );
        } on MissingPluginException {
          // Native restoration will enforce the same absolute deadline.
        }
      }
      return null;
    }
    if (Platform.isIOS &&
        configuration != null &&
        _iosForegroundEngine == null) {
      // Recreate the Dart pipeline after an iOS relaunch. The native plugin
      // has already restored Core Location/Core Bluetooth from UserDefaults;
      // these idempotent start calls reattach event streams and CMS tracking.
      _iosForegroundEngine = LocalizationEngine(
        configuration.venueName,
        baseURL: configuration.baseUrl,
        localizationMode: configuration.mode,
        skipAdapterSetup: true,
        stopAt: configuration.stopAt,
      );
    }
    return configuration;
  }

  static Future<LocalizationMode?> get activeMode async =>
      (await activeConfiguration)?.mode;

  static Future<DateTime?> get scheduledStopTime async =>
      (await activeConfiguration)?.stopAt;

  static Future<Duration?> get remainingDuration async {
    final stopAt = await scheduledStopTime;
    if (stopAt == null) return null;
    final remaining = stopAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  static Future<void> _waitUntilStopped(
    FlutterBackgroundService service,
  ) async {
    const pollInterval = Duration(milliseconds: 100);
    const maximumWait = Duration(seconds: 5);
    final deadline = DateTime.now().add(maximumWait);
    while (await service.isRunning() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
    }
  }
}

/// Requests and enables only the adapters required by [mode].
///
/// Call this from a foreground isolate because it may display system dialogs.
Future<void> prepareLocalizationAdapters(LocalizationMode mode) async {
  // Android BLE scanning can still require location permission depending on
  // OS/target version. iOS BLE-only sessions do not require location access.
  final needsLocationPermission =
      !Platform.isIOS || mode != LocalizationMode.onlyBle;
  if (needsLocationPermission) {
    final locationPermission = await AdapterManager.requestLocationPermission();
    if (!locationPermission.isGranted) {
      throw AdapterException(
        locationPermission.isPermanentlyDenied
            ? 'Location permission permanently denied. Please enable it in settings.'
            : 'Location permission denied.',
      );
    }

    if (Platform.isIOS && mode != LocalizationMode.onlyBle) {
      // Always authorization enables Core Location to relaunch the app for
      // significant changes. The user can decline the upgrade; When In Use
      // still supports an active background session with the iOS indicator.
      await AdapterManager.requestLocationAlwaysPermission();
    }
  }

  if (mode != LocalizationMode.onlyBle) {
    final gpsEnabled = await AdapterManager.isGpsEnabled() ||
        await AdapterManager.promptEnableGps();
    if (!gpsEnabled) {
      throw AdapterException(
        'GPS not enabled. Please enable location services.',
      );
    }
  }

  if (mode != LocalizationMode.onlyGps) {
    final bluetoothPermission =
        await AdapterManager.requestBluetoothPermission();
    if (!bluetoothPermission.isGranted) {
      throw AdapterException(
        bluetoothPermission.isPermanentlyDenied
            ? 'Bluetooth permission permanently denied. Please enable it in settings.'
            : 'Bluetooth permission denied.',
      );
    }

    final bluetoothEnabled = await AdapterManager.isBluetoothEnabled() ||
        await AdapterManager.promptEnableBluetooth();
    if (!bluetoothEnabled) {
      throw AdapterException(
        'Bluetooth not enabled. Please enable Bluetooth.',
      );
    }
  }
}

@pragma('vm:entry-point')
Future<void> localizationBackgroundServiceOnStart(
  ServiceInstance service,
) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await _runBackgroundService(service);
}

@pragma('vm:entry-point')
Future<bool> localizationIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  // Core Location and Core Bluetooth restore their native session when iOS
  // wakes the app. A short background-fetch isolate must not create a second
  // localization engine or Bluetooth central manager.
  return true;
}

Future<void> _runBackgroundService(ServiceInstance service) async {
  final configuration = await _readConfiguration();
  if (configuration == null) {
    await _stopFromBackground(service);
    return;
  }

  Future<void> stopService() => _stopFromBackground(service);
  service.on(_stopEvent).listen((_) => unawaited(stopService()));

  final remaining = configuration.stopAt?.difference(DateTime.now());
  if (remaining != null) {
    if (remaining <= Duration.zero) {
      await stopService();
      return;
    }
    _backgroundStopTimer = Timer(remaining, () => unawaited(stopService()));
  }

  _backgroundEngine = LocalizationEngine(
    configuration.venueName,
    baseURL: configuration.baseUrl,
    localizationMode: configuration.mode,
    skipAdapterSetup: true,
    stopAt: configuration.stopAt,
  );
}

Future<void> _stopFromBackground(ServiceInstance service) async {
  if (_backgroundStopInProgress) return;
  _backgroundStopInProgress = true;
  try {
    _backgroundStopTimer?.cancel();
    _backgroundStopTimer = null;
    await _backgroundEngine?.dispose();
    _backgroundEngine = null;
    await _clearConfiguration();
    service.stopSelf();
  } finally {
    _backgroundStopInProgress = false;
  }
}

Future<LocalizationServiceConfiguration?> _readConfiguration() async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.reload();
  final encoded = preferences.getString(_configurationKey);
  if (encoded == null) return null;

  try {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) return null;
    return LocalizationServiceConfiguration.fromJson(
      Map<String, Object?>.from(decoded),
    );
  } on FormatException {
    await preferences.remove(_configurationKey);
    return null;
  }
}

Future<void> _writeConfiguration(
  LocalizationServiceConfiguration configuration,
) async {
  final preferences = await SharedPreferences.getInstance();
  final saved = await preferences.setString(
    _configurationKey,
    jsonEncode(configuration.toJson()),
  );
  if (!saved) {
    throw StateError('Unable to persist background service configuration.');
  }
}

Future<void> _clearConfiguration() async {
  final preferences = await SharedPreferences.getInstance();
  await preferences.remove(_configurationKey);
}
