import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'localization_engine_platform_interface.dart';

/// An implementation of [LocalizationEnginePlatform] that uses method channels.
class MethodChannelLocalizationEngine extends LocalizationEnginePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('localization_engine');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
