import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'travel_photo_files.dart';

const _androidPicker = MethodChannel('projecttabi/travel_photos');

Future<List<PickedTravelPhoto>> pickTravelPhotos() async {
  final List<String> paths;
  if (Platform.isAndroid) {
    // Without this permission Android strips GPS tags from shared photos.
    await Permission.accessMediaLocation.request();
    paths =
        (await _androidPicker.invokeListMethod<String>('pickPhotos')) ??
        const [];
  } else {
    paths = [for (final file in await ImagePicker().pickMultiImage()) file.path];
  }
  final photos = <PickedTravelPhoto>[];
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      continue;
    }
    photos.add(
      PickedTravelPhoto(name: p.basename(path), bytes: await file.readAsBytes()),
    );
    if (path.contains('${Platform.pathSeparator}travel_import${Platform.pathSeparator}')) {
      // Copies made by the Android picker are only needed until read.
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }
  return photos;
}

Future<String> storeTravelPhoto(Uint8List bytes, {required String fileName}) async {
  final documents = await getApplicationDocumentsDirectory();
  final directory = Directory(p.join(documents.path, 'visit_record_images'));
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
  }
  final path = p.join(directory.path, fileName);
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

Future<ImageProvider?> loadRecordPhotoImage(String path) async {
  final file = File(path);
  return file.existsSync() ? FileImage(file) : null;
}
