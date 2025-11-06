import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'localization_engine_method_channel.dart';

abstract class LocalizationEnginePlatform extends PlatformInterface {
  /// Constructs a LocalizationEnginePlatform.
  LocalizationEnginePlatform() : super(token: _token);

  static final Object _token = Object();

  static LocalizationEnginePlatform _instance = MethodChannelLocalizationEngine();

  /// The default instance of [LocalizationEnginePlatform] to use.
  ///
  /// Defaults to [MethodChannelLocalizationEngine].
  static LocalizationEnginePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [LocalizationEnginePlatform] when
  /// they register themselves.
  static set instance(LocalizationEnginePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
