/// Only selects a filename extension; syncing never decodes or recompresses images.
String syncImageExtension(List<int> bytes) {
  bool has(int offset, List<int> signature) {
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

  if (has(0, [0xff, 0xd8, 0xff])) {
    return 'jpg';
  }
  if (has(0, [137, 80, 78, 71, 13, 10, 26, 10])) {
    return 'png';
  }
  if (has(0, 'RIFF'.codeUnits) && has(8, 'WEBP'.codeUnits)) {
    return 'webp';
  }
  if (has(0, 'GIF87a'.codeUnits) || has(0, 'GIF89a'.codeUnits)) {
    return 'gif';
  }
  if (has(0, [0x42, 0x4d])) {
    return 'bmp';
  }
  if (has(0, [0x49, 0x49, 0x2a, 0]) || has(0, [0x4d, 0x4d, 0, 0x2a])) {
    return 'tif';
  }
  if (bytes.length >= 16 && has(4, 'ftyp'.codeUnits)) {
    final boxSize =
        bytes[0] * 16777216 + bytes[1] * 65536 + bytes[2] * 256 + bytes[3];
    final brands = <String>{String.fromCharCodes(bytes.sublist(8, 12))};
    final end = boxSize < bytes.length ? boxSize : bytes.length;
    for (var offset = 16; offset + 4 <= end; offset += 4) {
      brands.add(String.fromCharCodes(bytes.sublist(offset, offset + 4)));
    }
    if (brands.any({'avif', 'avis'}.contains)) {
      return 'avif';
    }
    if (brands.any({'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis'}.contains)) {
      return 'heic';
    }
    if (brands.any({'mif1', 'msf1'}.contains)) {
      return 'heif';
    }
  }
  return 'bin';
}
