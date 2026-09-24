export 'sync_platform_stub.dart'
    if (dart.library.io) 'sync_platform_io.dart'
    if (dart.library.js_interop) 'sync_platform_web.dart';
