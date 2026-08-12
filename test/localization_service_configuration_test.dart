import 'package:flutter_test/flutter_test.dart';
import 'package:localization_engine/localization_engine.dart';

void main() {
  group('LocalizationServiceConfiguration', () {
    test('round-trips an indefinite configuration', () {
      const configuration = LocalizationServiceConfiguration(
        venueName: 'Iwayplus',
        baseUrl: 'https://dev.iwayplus.in',
        mode: LocalizationMode.bothGPSandBLE,
      );

      final restored = LocalizationServiceConfiguration.fromJson(
        configuration.toJson(),
      );

      expect(restored.venueName, configuration.venueName);
      expect(restored.baseUrl, configuration.baseUrl);
      expect(restored.mode, LocalizationMode.bothGPSandBLE);
      expect(restored.stopAt, isNull);
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
  });
}
