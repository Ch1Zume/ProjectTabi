import 'dart:typed_data';

export 'travel_photo_files_stub.dart'
    if (dart.library.io) 'travel_photo_files_io.dart';

/// A photo picked for the travel journal, read into memory.
class PickedTravelPhoto {
  const PickedTravelPhoto({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// File extension matching the image data, defaulting to jpg.
String travelPhotoExtension(Uint8List bytes) {
  bool startsWith(List<int> signature, [int offset = 0]) {
    if (bytes.length < offset + signature.length) {
      return false;
    }
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) {
        return false;
      }
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47])) {
    return 'png';
  }
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
      startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return 'webp';
  }
  if (startsWith(const [0x66, 0x74, 0x79, 0x70], 4)) {
    return 'heic';
  }
  return 'jpg';
}
