import 'package:data_repository/data_repository.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../config/config.dart';

/// Data_Repository, which sends this package's venue beacon request and keeps
/// its cache.
///
/// Main isolate only: it opens Hive boxes, and two isolates must not open the
/// same box. The background service's engine is handed its beacons instead
/// (see LocalizationServiceConfiguration.beacons).
///
/// A host such as navigation_sdk sets Data_Repository up with its own server
/// and key; then only the base URL this package was explicitly given is
/// applied, never this package's built-in key. A standalone app gets this
/// package's config.
Future<DataRepository> dataRepository() async {
  if (!DataRepository.isReady) {
    await Hive.initFlutter();
    return DataRepository.init(
        DataConfig(baseUrl: AppConfig.baseUrl, apiKey: AppConfig.apiKey));
  }
  final repo = DataRepository.instance;
  final url = AppConfig.url;
  if (url != null && url.isNotEmpty && url != repo.config.baseUrl) {
    repo.configure(repo.config.copyWith(baseUrl: url));
  }
  return repo;
}
