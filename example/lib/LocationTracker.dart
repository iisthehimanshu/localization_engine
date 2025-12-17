import 'dart:async';
import 'package:localization_engine/localization_engine.dart';

export 'package:localization_engine/Point.dart';


class LocationTracker {
  StreamSubscription<Pt?>? _subscription;

  Future<void> start() async {

    // 1. Listen to position updates
    _subscription = LocalizationEngine.scanResults.listen(
          (position) {
        if (position != null) {
          print('Current position: $position');
          // Update UI with new position
        }
      },
      onError: (error) {
        print('Localization error: $error');
      },
    );

    // 2. Start scanning
    await LocalizationEngine.startScanning(
      frequency: const Duration(seconds: 6), // Optional (Default Duration(seconds: 6))
      bufferSize: const Duration(seconds: 6), // Optional (Default Duration(seconds: 6))
      timeout: const Duration(minutes: 5),
      venueName: 'Ashoka University', // Required
    );
  }

  Future<Pt?> getCurrentLocation() async {
    return await LocalizationEngine.getCurrentLocation(venueName: 'Ashoka University');
  }

  Future<void> stop() async {
    // Stop scanning
    await LocalizationEngine.stopScanning();

    // Cancel subscription
    await _subscription?.cancel();

    // Cleanup resources
    await LocalizationEngine.dispose();
  }
}