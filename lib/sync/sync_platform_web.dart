import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../desktop/tauri_bridge.dart';
import 'sync_image_format.dart';

bool get syncUsesDesktop => isTauriLauncherAvailable;
bool get syncPlatformSupported =>
    isTauriLauncherAvailable &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);
Future<String?> syncStoreRead(String key) async =>
    (await invokeWebDavCommand('webdav_read_state', {'key': key}))['value']
        as String?;
Future<void> syncStoreWrite(String key, String value) async {
  await invokeWebDavCommand('webdav_write_state', {'key': key, 'value': value});
}

Future<String?> syncReadPassword(String key) async =>
    (await invokeWebDavCommand('webdav_read_password', {'key': key}))['value']
        as String?;
Future<void> syncWritePassword(String key, String value) async {
  await invokeWebDavCommand('webdav_write_password', {
    'key': key,
    'value': value,
  });
}

Future<String> syncWriteImage(String hash, List<int> bytes) async {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
    throw ArgumentError('Invalid hash');
  }
  final path = 'assets/webdav_sync/$hash.${syncImageExtension(bytes)}';
  await writeDesktopAsset(path: path, dataBase64: base64Encode(bytes));
  return path;
}

Future<Map<String, Object?>> syncDesktopRequest(
  String url,
  String method,
  Map<String, String> headers,
  List<int> body,
) => invokeWebDavCommand('webdav_request', {
  'url': url,
  'method': method,
  'headers': headers,
  'body': base64Encode(body),
});
