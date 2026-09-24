import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'sync_image_format.dart';

bool get syncUsesDesktop => false;
bool get syncPlatformSupported => Platform.isAndroid || Platform.isIOS;
const _secrets = FlutterSecureStorage();
Future<File> _file(String key) async {
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(key)) {
    throw ArgumentError('Invalid sync key');
  }
  final root = await getApplicationSupportDirectory();
  final dir = Directory(p.join(root.path, 'webdav_sync'));
  await dir.create(recursive: true);
  return File(p.join(dir.path, key));
}

Future<String?> syncStoreRead(String key) async {
  final file = await _file(key);
  return await file.exists() ? file.readAsString() : null;
}

Future<void> syncStoreWrite(String key, String value) async {
  final file = await _file(key);
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(value, flush: true);
  await temp.rename(file.path);
}

Future<String?> syncReadPassword(String key) =>
    _secrets.read(key: 'miriago_webdav_$key');
Future<void> syncWritePassword(String key, String value) => value.isEmpty
    ? _secrets.delete(key: 'miriago_webdav_$key')
    : _secrets.write(key: 'miriago_webdav_$key', value: value);
Future<String> syncWriteImage(String hash, List<int> bytes) async {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
    throw ArgumentError('Invalid hash');
  }
  final root = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(root.path, 'webdav_sync_assets'));
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, '$hash.${syncImageExtension(bytes)}'));
  final temp = File('${file.path}.tmp');
  await temp.writeAsBytes(bytes, flush: true);
  await temp.rename(file.path);
  return file.path;
}

Future<Map<String, Object?>> syncDesktopRequest(
  String url,
  String method,
  Map<String, String> headers,
  List<int> body,
) async => throw UnsupportedError('Desktop only');
