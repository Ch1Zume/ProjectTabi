import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

/// Administrative depth of a [RegionFeature].
enum RegionLevel { country, admin1, admin2 }

/// One closed ring stored as interleaved longitude/latitude degrees.
class RegionRing {
  RegionRing(this.coordinates);

  final Float64List coordinates;

  int get length => coordinates.length ~/ 2;

  double lonAt(int index) => coordinates[index * 2];

  double latAt(int index) => coordinates[index * 2 + 1];

  List<LatLng> toLatLngs() => [
    for (var i = 0; i < length; i++) LatLng(latAt(i), lonAt(i)),
  ];
}

/// A polygon with its exterior ring first, followed by holes.
///
/// Exterior rings are counter-clockwise and holes clockwise in lon/lat.
class RegionPolygon {
  RegionPolygon(this.rings);

  final List<RegionRing> rings;

  RegionRing get exterior => rings.first;

  Iterable<RegionRing> get holes => rings.skip(1);
}

class RegionBounds {
  const RegionBounds(this.west, this.south, this.east, this.north);

  final double west;
  final double south;
  final double east;
  final double north;

  bool contains(double lon, double lat, {double margin = 0}) =>
      lon >= west - margin &&
      lon <= east + margin &&
      lat >= south - margin &&
      lat <= north + margin;

  bool overlaps(RegionBounds other) =>
      west <= other.east &&
      east >= other.west &&
      south <= other.north &&
      north >= other.south;

  RegionBounds expand(double margin) => RegionBounds(
    west - margin,
    math.max(-90, south - margin),
    east + margin,
    math.min(90, north + margin),
  );
}

class RegionFeature {
  RegionFeature({
    required this.id,
    required this.name,
    required this.parentId,
    required this.level,
    required this.hasChildren,
    required this.label,
    required this.polygons,
  }) : bounds = _boundsOf(polygons);

  final String id;
  final String name;

  /// Country code for admin 1, admin 1 id for admin 2, empty for countries.
  final String parentId;
  final RegionLevel level;

  /// Whether a deeper level of divisions exists for this region.
  final bool hasChildren;
  final LatLng label;
  final List<RegionPolygon> polygons;
  final RegionBounds bounds;

  /// Bounds of the main landmass, ignoring far-flung small islands so that
  /// e.g. the USA is not stretched across the antimeridian by the Aleutians.
  late final RegionBounds mainBounds = _mainBoundsOf(polygons);

  /// The country code this region belongs to.
  String get countryCode => switch (level) {
    RegionLevel.country => id,
    RegionLevel.admin1 => parentId,
    RegionLevel.admin2 => _countryOfAdmin2(id),
  };

  bool contains(double lon, double lat) {
    if (!bounds.contains(lon, lat)) {
      return false;
    }
    for (final polygon in polygons) {
      var inside = false;
      for (final ring in polygon.rings) {
        if (_ringContains(ring, lon, lat)) {
          inside = !inside;
        }
      }
      if (inside) {
        return true;
      }
    }
    return false;
  }

  /// Approximate distance in degrees from a point to the region's border.
  double distanceTo(double lon, double lat) {
    final scale = math.cos(lat * math.pi / 180).abs().clamp(0.2, 1.0);
    var best = double.infinity;
    for (final polygon in polygons) {
      for (final ring in polygon.rings) {
        final count = ring.length;
        for (var i = 0, j = count - 1; i < count; j = i++) {
          final d = _segmentDistance(
            lon * scale,
            lat,
            ring.lonAt(j) * scale,
            ring.latAt(j),
            ring.lonAt(i) * scale,
            ring.latAt(i),
          );
          if (d < best) {
            best = d;
          }
        }
      }
    }
    return best;
  }

  List<LatLng> outlineAt(int polygonIndex) =>
      polygons[polygonIndex].exterior.toLatLngs();
}

String _countryOfAdmin2(String id) => switch (id.split('-').first) {
  'CN' => 'CHN',
  'JP' => 'JPN',
  final prefix => prefix,
};

bool _ringContains(RegionRing ring, double lon, double lat) {
  var inside = false;
  final count = ring.length;
  for (var i = 0, j = count - 1; i < count; j = i++) {
    final yi = ring.latAt(i);
    final yj = ring.latAt(j);
    if ((yi > lat) != (yj > lat)) {
      final xi = ring.lonAt(i);
      final xj = ring.lonAt(j);
      final crossing = (xj - xi) * (lat - yi) / (yj - yi) + xi;
      if (lon < crossing) {
        inside = !inside;
      }
    }
  }
  return inside;
}

double _segmentDistance(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final dx = bx - ax;
  final dy = by - ay;
  final lengthSquared = dx * dx + dy * dy;
  var t = lengthSquared == 0
      ? 0.0
      : ((px - ax) * dx + (py - ay) * dy) / lengthSquared;
  t = t.clamp(0.0, 1.0);
  final cx = ax + t * dx - px;
  final cy = ay + t * dy - py;
  return math.sqrt(cx * cx + cy * cy);
}

RegionBounds _mainBoundsOf(List<RegionPolygon> polygons) {
  final parts = [for (final polygon in polygons) _boundsOf([polygon])];
  double area(RegionBounds b) => (b.east - b.west) * (b.north - b.south);
  final largest = parts.fold<double>(0, (value, b) => math.max(value, area(b)));
  final main = parts.where((b) => area(b) >= largest * 0.05);
  if (main.isEmpty) {
    return _boundsOf(polygons);
  }
  return RegionBounds(
    main.map((b) => b.west).reduce(math.min),
    main.map((b) => b.south).reduce(math.min),
    main.map((b) => b.east).reduce(math.max),
    main.map((b) => b.north).reduce(math.max),
  );
}

RegionBounds _boundsOf(List<RegionPolygon> polygons) {
  var west = double.infinity;
  var south = double.infinity;
  var east = double.negativeInfinity;
  var north = double.negativeInfinity;
  for (final polygon in polygons) {
    final ring = polygon.exterior;
    for (var i = 0; i < ring.length; i++) {
      final lon = ring.lonAt(i);
      final lat = ring.latAt(i);
      west = math.min(west, lon);
      east = math.max(east, lon);
      south = math.min(south, lat);
      north = math.max(north, lat);
    }
  }
  if (west > east) {
    return const RegionBounds(0, 0, 0, 0);
  }
  return RegionBounds(west, south, east, north);
}

/// Features of one boundary file plus decorative lines (e.g. the nine-dash
/// line) that are drawn but never selected.
class RegionSet {
  RegionSet(this.features, this.lines)
    : _byId = {for (final feature in features) feature.id: feature};

  final List<RegionFeature> features;
  final List<RegionRing> lines;
  final Map<String, RegionFeature> _byId;

  RegionFeature? operator [](String id) => _byId[id];

  Iterable<RegionFeature> childrenOf(String parentId) =>
      features.where((feature) => feature.parentId == parentId);

  /// Finds the region containing a point. Points just off a simplified
  /// coastline fall back to the nearest region within [tolerance] degrees.
  RegionFeature? locate(
    double lon,
    double lat, {
    double tolerance = 0,
    bool Function(RegionFeature feature)? where,
  }) {
    for (final feature in features) {
      if ((where == null || where(feature)) && feature.contains(lon, lat)) {
        return feature;
      }
    }
    if (tolerance <= 0) {
      return null;
    }
    RegionFeature? nearest;
    var nearestDistance = tolerance;
    for (final feature in features) {
      if (where != null && !where(feature)) {
        continue;
      }
      if (!feature.bounds.contains(lon, lat, margin: tolerance)) {
        continue;
      }
      final distance = feature.distanceTo(lon, lat);
      if (distance <= nearestDistance) {
        nearest = feature;
        nearestDistance = distance;
      }
    }
    return nearest;
  }
}

class RegionFormatException implements Exception {
  const RegionFormatException(this.message);

  final String message;

  @override
  String toString() => 'RegionFormatException: $message';
}

/// Decodes the PTRG format written by tool/footprint/build_regions.py.
RegionSet decodeRegionSet(Uint8List bytes, RegionLevel level) {
  final reader = _ByteReader(bytes);
  if (bytes.length < 5 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x54 ||
      bytes[2] != 0x52 ||
      bytes[3] != 0x47) {
    throw const RegionFormatException('missing PTRG header');
  }
  reader.offset = 4;
  final version = reader.byte();
  if (version != 1) {
    throw RegionFormatException('unsupported version $version');
  }
  final featureCount = reader.varint();
  final features = <RegionFeature>[];
  for (var f = 0; f < featureCount; f++) {
    final id = reader.string();
    final name = reader.string();
    final parentId = reader.string();
    final flags = reader.varint();
    final labelLon = reader.zigzag() / _quantization;
    final labelLat = reader.zigzag() / _quantization;
    final polygonCount = reader.varint();
    final polygons = <RegionPolygon>[];
    for (var p = 0; p < polygonCount; p++) {
      final ringCount = reader.varint();
      polygons.add(
        RegionPolygon([for (var r = 0; r < ringCount; r++) reader.ring()]),
      );
    }
    features.add(
      RegionFeature(
        id: id,
        name: name,
        parentId: parentId,
        level: level,
        hasChildren: flags & 1 == 1,
        label: LatLng(labelLat, labelLon),
        polygons: polygons,
      ),
    );
  }
  final lineCount = reader.varint();
  final lines = [for (var i = 0; i < lineCount; i++) reader.ring()];
  return RegionSet(features, lines);
}

const _quantization = 1e5;

class _ByteReader {
  _ByteReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  int byte() {
    if (offset >= bytes.length) {
      throw const RegionFormatException('unexpected end of data');
    }
    return bytes[offset++];
  }

  // Values stay below 2^31 so this is safe with 32-bit web bit operations.
  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final value = byte();
      result |= (value & 0x7f) << shift;
      if (value < 0x80) {
        return result;
      }
      shift += 7;
    }
  }

  int zigzag() {
    final value = varint();
    return (value >> 1) ^ -(value & 1);
  }

  String string() {
    final length = varint();
    final start = offset;
    offset += length;
    if (offset > bytes.length) {
      throw const RegionFormatException('string past end of data');
    }
    return utf8.decode(Uint8List.sublistView(bytes, start, offset));
  }

  RegionRing ring() {
    final count = varint();
    final coordinates = Float64List(count * 2);
    var lon = 0;
    var lat = 0;
    for (var i = 0; i < count; i++) {
      lon += zigzag();
      lat += zigzag();
      coordinates[i * 2] = lon / _quantization;
      coordinates[i * 2 + 1] = lat / _quantization;
    }
    return RegionRing(coordinates);
  }
}

/// Loads and caches boundary assets bundled under assets/footprint/.
class RegionCatalog {
  RegionCatalog({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  final Map<String, Future<RegionSet?>> _cache = {};

  static const _root = 'assets/footprint';

  Future<RegionSet> world() async =>
      (await _load('$_root/world.ptrg', RegionLevel.country))!;

  /// First-level divisions of [countryCode], or null when not bundled.
  Future<RegionSet?> admin1(String countryCode) =>
      _load('$_root/admin1/$countryCode.ptrg', RegionLevel.admin1);

  /// City-level divisions of [countryCode], or null when not bundled.
  Future<RegionSet?> admin2(String countryCode) =>
      _load('$_root/admin2/$countryCode.ptrg', RegionLevel.admin2);

  Future<RegionSet?> _load(String path, RegionLevel level) {
    return _cache.putIfAbsent(path, () async {
      final ByteData data;
      try {
        data = await _bundle.load(path);
      } catch (_) {
        // Countries without bundled divisions have no file.
        return null;
      }
      return decodeRegionSet(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        level,
      );
    });
  }
}
