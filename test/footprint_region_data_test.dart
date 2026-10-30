import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:project_tabi/footprint/footprint_data.dart';
import 'package:project_tabi/footprint/region_data.dart';

class _FileAssetBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final file = File(key);
    if (!file.existsSync()) {
      throw FlutterError('Unable to load asset: $key');
    }
    final bytes = file.readAsBytesSync();
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

void main() {
  late RegionCatalog catalog;
  late RegionSet world;

  setUpAll(() async {
    catalog = RegionCatalog(bundle: _FileAssetBundle());
    world = await catalog.world();
  });

  Future<List<String>?> placeOf(double lat, double lon) async {
    final place = await FootprintIndex.locate(catalog, world, LatLng(lat, lon));
    return place?.regionIds;
  }

  test('world uses the China worldview with short names', () {
    expect(world['CHN']?.name, '中国');
    expect(world['JPN']?.name, '日本');
    expect(world['KOR']?.name, '韩国');
    expect(world['TWN'], isNull);
    expect(world['HKG'], isNull);
    expect(world['CHN']!.hasChildren, isTrue);
    expect(world.lines, isNotEmpty, reason: 'nine-dash line');
  });

  test('locates points in Japan down to municipalities', () async {
    expect(await placeOf(34.8843, 135.8076), ['JPN', 'JP-26', 'JP-26204']);
    // Designated cities and the 23 special wards are single units.
    expect(await placeOf(35.0116, 135.7681), ['JPN', 'JP-26', 'JP-26100']);
    expect(await placeOf(35.6938, 139.7036), ['JPN', 'JP-13', 'JP-13100']);
  });

  test('locates points in China down to prefecture cities', () async {
    expect(await placeOf(30.2741, 120.1551), ['CHN', 'CN-330000', 'CN-330100']);
    // Municipalities and SARs are city-level leaves.
    expect(await placeOf(31.2304, 121.4737), ['CHN', 'CN-310000']);
    expect(await placeOf(22.3193, 114.1694), ['CHN', 'CN-810000']);
    expect(await placeOf(25.0330, 121.5654), ['CHN', 'CN-710000']);
  });

  test('other countries stop at first-level divisions', () async {
    expect(await placeOf(37.5665, 126.9780), ['KOR', 'KR-11']);
    expect(await placeOf(48.8566, 2.3522), ['FRA', 'FR-75']);
  });

  test('coastal points just outside simplified borders still match', () async {
    // Enoshima, a small island off the Kanagawa coast.
    final place = await placeOf(35.2995, 139.4800);
    expect(place?.take(2), ['JPN', 'JP-14']);
  });

  test('open ocean has no region', () async {
    expect(await placeOf(0, -140), isNull);
  });

  test('rejects data without the PTRG header', () {
    expect(
      () => decodeRegionSet(Uint8List.fromList([1, 2, 3, 4, 5]), RegionLevel.country),
      throwsA(isA<RegionFormatException>()),
    );
  });
}
