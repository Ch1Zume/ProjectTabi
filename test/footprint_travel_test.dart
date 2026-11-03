import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:project_tabi/footprint/footprint_data.dart';
import 'package:project_tabi/footprint/footprint_preferences.dart';
import 'package:project_tabi/footprint/region_data.dart';
import 'package:project_tabi/footprint/travel_photo_files.dart';
import 'package:project_tabi/footprint/travel_photo_metadata.dart';
import 'package:project_tabi/plan/pilgrimage_models.dart';

class _FileAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final file = File(key);
    if (!file.existsSync()) {
      throw FlutterError('Unable to load asset: $key');
    }
    return ByteData.sublistView(file.readAsBytesSync());
  }
}

/// Rational EXIF value from (numerator, denominator) pairs.
img.IfdValueRational _rationals(List<(int, int)> parts) {
  final value = img.IfdValueRational(parts.first.$1, parts.first.$2);
  for (final part in parts.skip(1)) {
    value.value.addAll(img.IfdValueRational(part.$1, part.$2).value);
  }
  return value;
}

Uint8List _jpegWithGps({
  required List<(int, int)> latitude,
  required String latitudeRef,
  required List<(int, int)> longitude,
  required String longitudeRef,
  String? takenAt,
}) {
  final image = img.Image(width: 4, height: 4);
  final gps = image.exif.gpsIfd;
  gps.data[0x0001] = img.IfdValueAscii(latitudeRef);
  gps.data[0x0002] = _rationals(latitude);
  gps.data[0x0003] = img.IfdValueAscii(longitudeRef);
  gps.data[0x0004] = _rationals(longitude);
  if (takenAt != null) {
    image.exif.exifIfd.data[img.exifTagNameToID['DateTimeOriginal']!] =
        img.IfdValueAscii(takenAt);
  }
  return img.encodeJpg(image);
}

const _work = PilgrimageWork(
  id: 'w',
  title: 'Work',
  subtitle: '',
  city: '',
  source: WorkSource.manual,
);

FootprintEntry _entry(
  String id,
  double lat,
  double lon, {
  PointSource source = PointSource.anitabi,
  DateTime? at,
}) {
  return FootprintEntry(
    record: PilgrimageVisitRecord(
      id: id,
      planId: 'p',
      pointId: id,
      workId: 'w',
      photoPath: '',
      referenceMode: 'overlay',
      capturedAt: at ?? DateTime(2026),
    ),
    point: PilgrimagePoint(
      id: id,
      work: _work,
      name: id,
      subtitle: '',
      position: LatLng(lat, lon),
      episodeLabel: '',
      referenceLabel: '',
      source: source,
    ),
    planName: 'Plan',
  );
}

void main() {
  group('travel photo metadata', () {
    test('reads degrees, minutes and seconds with hemisphere', () {
      final bytes = _jpegWithGps(
        latitude: [(34, 1), (53, 1), (348, 100)],
        latitudeRef: 'N',
        longitude: [(135, 1), (48, 1), (2736, 100)],
        longitudeRef: 'E',
        takenAt: '2026:02:10 14:30:05',
      );
      final metadata = readTravelPhotoMetadata(bytes);
      expect(metadata.position!.latitude, closeTo(34.8843, 1e-4));
      expect(metadata.position!.longitude, closeTo(135.8076, 1e-4));
      expect(metadata.capturedAt, DateTime(2026, 2, 10, 14, 30, 5));
    });

    test('south and west references are negative', () {
      final bytes = _jpegWithGps(
        latitude: [(33, 1), (52, 1), (0, 1)],
        latitudeRef: 'S',
        longitude: [(151, 1), (12, 1), (0, 1)],
        longitudeRef: 'W',
      );
      final position = readTravelPhotoMetadata(bytes).position!;
      expect(position.latitude, closeTo(-33.8667, 1e-4));
      expect(position.longitude, closeTo(-151.2, 1e-4));
    });

    test('photos without GPS or with a 0/0 fix have no position', () {
      expect(
        readTravelPhotoMetadata(img.encodeJpg(img.Image(width: 2, height: 2)))
            .position,
        isNull,
      );
      final zero = _jpegWithGps(
        latitude: [(0, 1)],
        latitudeRef: 'N',
        longitude: [(0, 1)],
        longitudeRef: 'E',
      );
      expect(readTravelPhotoMetadata(zero).position, isNull);
      expect(readTravelPhotoMetadata(Uint8List.fromList([1, 2, 3])).position, isNull);
    });

    test('detects image formats for stored file names', () {
      expect(travelPhotoExtension(img.encodeJpg(img.Image(width: 1, height: 1))), 'jpg');
      expect(travelPhotoExtension(img.encodePng(img.Image(width: 1, height: 1))), 'png');
    });
  });

  group('footprint filter', () {
    late FootprintIndex index;

    setUpAll(() async {
      final catalog = RegionCatalog(bundle: _FileAssetBundle());
      index = await FootprintIndex.build(
        catalog,
        FootprintSource(
          unlocatedCount: 0,
          entries: [
            _entry('uji', 34.8843, 135.8076, at: DateTime(2026, 3)),
            _entry('kyoto-trip', 35.0116, 135.7681,
                source: PointSource.travel, at: DateTime(2026, 2)),
            _entry('hangzhou-trip', 30.2741, 120.1551,
                source: PointSource.travel, at: DateTime(2026, 1)),
          ],
        ),
      );
    });

    test('all footprints count both kinds', () {
      expect(index.countFor('JP-26'), 2);
      expect(index.isVisited('CHN'), isTrue);
      expect(index.visitedCountries.map((c) => c.id), containsAll(['JPN', 'CHN']));
    });

    test('travel only hides pilgrimage records', () {
      final travel = index.filtered(FootprintFilter.travel);
      expect(travel.entries.map((e) => e.record.id), ['kyoto-trip', 'hangzhou-trip']);
      expect(travel.countFor('JP-26'), 1);
      expect(travel.isVisited('JP-26204'), isFalse);
      expect(travel.allEntries, hasLength(3));
    });

    test('pilgrimage only hides travel photos', () {
      final pilgrimage = index.filtered(FootprintFilter.pilgrimage);
      expect(pilgrimage.isVisited('CHN'), isFalse);
      expect(pilgrimage.countFor('JPN'), 1);
      expect(pilgrimage.visitedPlaceCount, 1);
    });

    test('representative photo is the newest unless picked', () {
      expect(index.representativeOf('JP-26', const {})?.record.id, 'uji');
      expect(
        index.representativeOf('JP-26', const {'JP-26': 'kyoto-trip'})?.record.id,
        'kyoto-trip',
      );
      // A pick hidden by the filter falls back to the newest shown record.
      expect(
        index
            .filtered(FootprintFilter.pilgrimage)
            .representativeOf('JP-26', const {'JP-26': 'kyoto-trip'})
            ?.record
            .id,
        'uji',
      );
    });
  });

  test('travel plans are recognised by points or markers', () {
    PilgrimagePlan plan({String name = 'Kyoto', String area = '', List<PilgrimagePoint> points = const []}) =>
        PilgrimagePlan(
          id: 'plan',
          name: name,
          area: area,
          works: const [],
          points: points,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );
    expect(isTravelPlan(plan()), isFalse);
    expect(isTravelPlan(plan(name: travelPlanName, area: travelPlanArea)), isTrue);
    expect(isTravelPlan(plan(), knownId: 'plan'), isTrue);
    expect(
      isTravelPlan(plan(points: [_entry('t', 35, 135, source: PointSource.travel).point])),
      isTrue,
    );
  });
}
