/// Resolves the [ScanSource] appropriate to the platform this bundle runs on.
///
/// The conditional import keeps `dart:js_interop` out of native builds and the
/// platform channels out of web builds, so neither has to tolerate the
/// other's dependencies.
library;

export 'scan_source_locator_io.dart'
    if (dart.library.js_interop) 'scan_source_locator_web.dart';
