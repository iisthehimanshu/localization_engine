import 'dart:async';
import 'package:localization_engine/localization_engine.dart';


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
      venueName: 'IITDelhi', // Required
    );
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