import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

import '../desktop/desktop_asset_image.dart';
import '../desktop/tauri_bridge.dart' as tauri;
import 'travel_photo_files.dart';

// Windows runs the web build inside Tauri: photos come from the browser file
// dialog with EXIF intact and are stored as desktop assets.

Future<List<PickedTravelPhoto>> pickTravelPhotos() async {
  final files = await ImagePicker().pickMultiImage();
  return [
    for (final file in files)
      PickedTravelPhoto(name: file.name, bytes: await file.readAsBytes()),
  ];
}

Future<String> storeTravelPhoto(Uint8List bytes, {required String fileName}) async {
  if (!tauri.isTauriLauncherAvailable) {
    throw StateError('旅行照片只能在 Android 或 Windows 客户端中保存');
  }
  final path = 'assets/visit_photos/$fileName';
  await tauri.writeDesktopAsset(path: path, dataBase64: base64Encode(bytes));
  return path;
}

Future<ImageProvider?> loadRecordPhotoImage(String path) async {
  if (!isDesktopAssetPath(path)) {
    return null;
  }
  final dataUrl = await loadDesktopAssetDataUrl(path);
  final comma = dataUrl?.indexOf(',') ?? -1;
  if (dataUrl == null || comma < 0) {
    return null;
  }
  return MemoryImage(base64Decode(dataUrl.substring(comma + 1)));
}
