import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/localization_engine.dart';

void main() {
  group('LocalizationServiceConfiguration', () {
    test('round-trips an indefinite configuration', () {
      const configuration = LocalizationServiceConfiguration(
        venueName: 'Iwayplus',
        baseUrl: 'https://dev.iwayplus.in',
        mode: LocalizationMode.bothGPSandBLE,
        surroundingDeviceScanInterval: Duration(seconds: 25),
      );

      final restored = LocalizationServiceConfiguration.fromJson(
        configuration.toJson(),
      );

      expect(restored.venueName, configuration.venueName);
      expect(restored.baseUrl, configuration.baseUrl);
      expect(restored.mode, LocalizationMode.bothGPSandBLE);
      expect(restored.stopAt, isNull);
      expect(
          restored.surroundingDeviceScanInterval, const Duration(seconds: 25));
    });

    for (final mode in LocalizationMode.values) {
      test('restores ${mode.name} mode', () {
        final configuration = LocalizationServiceConfiguration(
          venueName: 'Iwayplus',
          mode: mode,
        );

        final restored = LocalizationServiceConfiguration.fromJson(
          configuration.toJson(),
        );

        expect(restored.mode, mode);
      });
    }

    test('restores an already-expired absolute deadline', () {
      final stopAt = DateTime.now().subtract(const Duration(minutes: 1));
      final configuration = LocalizationServiceConfiguration(
        venueName: 'Iwayplus',
        mode: LocalizationMode.onlyGps,
        stopAt: stopAt,
      );

      final restored = LocalizationServiceConfiguration.fromJson(
        configuration.toJson(),
      );

      expect(
        restored.stopAt?.millisecondsSinceEpoch,
        stopAt.millisecondsSinceEpoch,
      );
      expect(restored.stopAt!.isBefore(DateTime.now()), isTrue);
    });

    test('round-trips persisted accuracy calibration', () {
      const configuration = LocalizationServiceConfiguration(
        venueName: 'Iwayplus',
        mode: LocalizationMode.bothGPSandBLE,
        beaconCalibrations: <String, BeaconSignalCalibration>{
          'IW1': BeaconSignalCalibration(rssiOffset: 2.5, reliability: 0.8),
        },
        pixelsPerMeterByFloor: <String, double>{'B1:0': 4.2},
        geoTransformsByFloor: <String, FloorGeoTransform>{
          'B1:0': FloorGeoTransform(
            latitudeOrigin: 28,
            longitudeOrigin: 77,
            latitudePerPixelX: 0.001,
            latitudePerPixelY: 0,
            longitudePerPixelX: 0,
            longitudePerPixelY: 0.001,
          ),
        },
      );

      final restored = LocalizationServiceConfiguration.fromJson(
        configuration.toJson(),
      );

      expect(restored.beaconCalibrations['IW1']!.rssiOffset, 2.5);
      expect(restored.beaconCalibrations['IW1']!.reliability, 0.8);
      expect(restored.pixelsPerMeterByFloor['B1:0'], 4.2);
      expect(
        restored.geoTransformsByFloor['B1:0']!.convert(10, 20),
        <double>[28.01, 77.02],
      );
    });

    test('rejects unknown modes', () {
      expect(
        () => LocalizationServiceConfiguration.fromJson(
          const <String, Object?>{
            'venueName': 'Iwayplus',
            'mode': 'unsupported',
          },
        ),
        throwsFormatException,
      );
    });

    test('rejects a non-positive surrounding-device interval', () {
      expect(
        () => LocalizationServiceConfiguration.fromJson(
          const <String, Object?>{
            'venueName': 'Iwayplus',
            'mode': 'bothGPSandBLE',
            'surroundingDeviceScanIntervalMs': 0,
          },
        ),
        throwsFormatException,
      );
    });
  });

  group('LocalizationBackgroundService validation', () {
    test('rejects zero duration before accessing platform services', () {
      expect(
        LocalizationBackgroundService.start(
          venueName: 'Iwayplus',
          duration: Duration.zero,
        ),
        throwsArgumentError,
      );
    });

    test('rejects negative duration before accessing platform services', () {
      expect(
        LocalizationBackgroundService.start(
          venueName: 'Iwayplus',
          duration: const Duration(seconds: -1),
        ),
        throwsArgumentError,
      );
    });

    test('rejects zero surrounding-device interval before platform access', () {
      expect(
        LocalizationBackgroundService.start(
          venueName: 'Iwayplus',
          surroundingDeviceScanInterval: Duration.zero,
        ),
        throwsArgumentError,
      );
    });
  });
}
