import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

/// Location and capture time read from a photo's EXIF data.
class TravelPhotoMetadata {
  const TravelPhotoMetadata({this.position, this.capturedAt});

  final LatLng? position;
  final DateTime? capturedAt;
}

TravelPhotoMetadata readTravelPhotoMetadata(Uint8List bytes) {
  try {
    final exif = img.decodeJpgExif(bytes);
    if (exif == null || exif.isEmpty) {
      return const TravelPhotoMetadata();
    }
    return TravelPhotoMetadata(
      position: _gpsPosition(exif.gpsIfd),
      capturedAt: _captureTime(exif),
    );
  } catch (_) {
    return const TravelPhotoMetadata();
  }
}

LatLng? _gpsPosition(img.IfdDirectory gps) {
  final latitude = _degrees(gps.data[0x0002], gps.gpsLatitudeRef, 'S');
  final longitude = _degrees(gps.data[0x0004], gps.gpsLongitudeRef, 'W');
  if (latitude == null || longitude == null) {
    return null;
  }
  // Cameras without a fix often write 0/0.
  if (latitude == 0 && longitude == 0) {
    return null;
  }
  if (latitude.abs() > 90 || longitude.abs() > 180) {
    return null;
  }
  return LatLng(latitude, longitude);
}

/// Converts degrees/minutes/seconds rationals to signed decimal degrees.
double? _degrees(img.IfdValue? value, String? ref, String negativeRef) {
  if (value == null || value.length == 0) {
    return null;
  }
  var degrees = value.toDouble();
  if (value.length >= 2) {
    degrees += value.toDouble(1) / 60;
  }
  if (value.length >= 3) {
    degrees += value.toDouble(2) / 3600;
  }
  if (degrees.isNaN || degrees.isInfinite) {
    return null;
  }
  final negative = ref?.trim().toUpperCase().startsWith(negativeRef) ?? false;
  return negative ? -degrees : degrees;
}

DateTime? _captureTime(img.ExifData exif) {
  for (final tag in const ['DateTimeOriginal', 'DateTimeDigitized', 'DateTime']) {
    final id = img.exifTagNameToID[tag];
    if (id == null) {
      continue;
    }
    final value =
        exif.exifIfd.data[id]?.toString() ?? exif.imageIfd.data[id]?.toString();
    final parsed = _parseExifDateTime(value);
    if (parsed != null) {
      return parsed;
    }
  }
  return null;
}

DateTime? _parseExifDateTime(String? value) {
  final match = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(value?.trim() ?? '');
  if (match == null) {
    return null;
  }
  final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  if (parts[0] < 1900 || parts[1] < 1 || parts[2] < 1) {
    return null;
  }
  return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
}
