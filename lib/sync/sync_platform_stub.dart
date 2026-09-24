bool get syncUsesDesktop => false;
bool get syncPlatformSupported => false;
Future<String?> syncStoreRead(String key) async => null;
Future<void> syncStoreWrite(String key, String value) async =>
    throw UnsupportedError('WebDAV');
Future<String?> syncReadPassword(String key) async => null;
Future<void> syncWritePassword(String key, String value) async =>
    throw UnsupportedError('WebDAV');
Future<String> syncWriteImage(String hash, List<int> bytes) async =>
    throw UnsupportedError('WebDAV');
Future<Map<String, Object?>> syncDesktopRequest(
  String url,
  String method,
  Map<String, String> headers,
  List<int> body,
) async => throw UnsupportedError('WebDAV');
