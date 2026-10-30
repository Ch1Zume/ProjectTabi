import 'package:latlong2/latlong.dart';

import '../data/pilgrimage_repository.dart';
import '../plan/pilgrimage_models.dart';
import 'region_data.dart';

/// A visit record together with the point that gives it a location.
class FootprintEntry {
  const FootprintEntry({
    required this.record,
    required this.point,
    required this.planName,
  });

  final PilgrimageVisitRecord record;
  final PilgrimagePoint point;
  final String planName;

  LatLng get position => point.position;
}

/// Region ids an entry falls into, from country down to the deepest level
/// available for that country.
class FootprintPlace {
  const FootprintPlace(this.regionIds);

  final List<String> regionIds;

  String get countryCode => regionIds.first;

  String get deepestId => regionIds.last;
}

class FootprintSource {
  const FootprintSource({required this.entries, required this.unlocatedCount});

  final List<FootprintEntry> entries;

  /// Records whose point was deleted, so they have no coordinates.
  final int unlocatedCount;
}

/// Collects visit records of every plan.
Future<FootprintSource> loadFootprintSource(
  PilgrimageRepository repository,
) async {
  final plans = await repository.loadPlans();
  final entries = <FootprintEntry>[];
  var unlocated = 0;
  for (final plan in plans) {
    final records = await repository.loadVisitRecords(plan.id);
    if (records.isEmpty) {
      continue;
    }
    final pointsById = {for (final point in plan.points) point.id: point};
    for (final record in records) {
      final point = pointsById[record.pointId];
      if (point == null) {
        unlocated++;
        continue;
      }
      entries.add(
        FootprintEntry(record: record, point: point, planName: plan.name),
      );
    }
  }
  entries.sort((a, b) => b.record.capturedAt.compareTo(a.record.capturedAt));
  return FootprintSource(entries: entries, unlocatedCount: unlocated);
}

/// Visit records grouped by the regions they fall into.
class FootprintIndex {
  FootprintIndex._({
    required this.world,
    required this.entries,
    required this.unlocatedCount,
    required this._entriesByRegion,
    required this._leafRegionIds,
  });

  final RegionSet world;
  final List<FootprintEntry> entries;
  final int unlocatedCount;
  final Map<String, List<FootprintEntry>> _entriesByRegion;
  final Set<String> _leafRegionIds;

  /// Coastline simplification can push seaside points outside every
  /// polygon, so lookups fall back to the nearest region within these
  /// distances (degrees).
  static const _countryTolerance = 0.35;
  static const _admin1Tolerance = 0.2;
  static const _admin2Tolerance = 0.08;

  static Future<FootprintIndex> build(
    RegionCatalog catalog,
    FootprintSource source,
  ) async {
    final world = await catalog.world();
    final byRegion = <String, List<FootprintEntry>>{};
    final leaves = <String>{};
    for (final entry in source.entries) {
      final place = await locate(catalog, world, entry.position);
      if (place == null) {
        continue;
      }
      for (final id in place.regionIds) {
        (byRegion[id] ??= []).add(entry);
      }
      leaves.add(place.deepestId);
    }
    return FootprintIndex._(
      world: world,
      entries: source.entries,
      unlocatedCount: source.unlocatedCount,
      entriesByRegion: byRegion,
      leafRegionIds: leaves,
    );
  }

  static Future<FootprintPlace?> locate(
    RegionCatalog catalog,
    RegionSet world,
    LatLng position,
  ) async {
    final lon = position.longitude;
    final lat = position.latitude;
    final country = world.locate(lon, lat, tolerance: _countryTolerance);
    if (country == null) {
      return null;
    }
    final ids = [country.id];
    if (!country.hasChildren) {
      return FootprintPlace(ids);
    }
    final admin1Set = await catalog.admin1(country.id);
    final admin1 = admin1Set?.locate(lon, lat, tolerance: _admin1Tolerance);
    if (admin1 == null) {
      return FootprintPlace(ids);
    }
    ids.add(admin1.id);
    if (!admin1.hasChildren) {
      return FootprintPlace(ids);
    }
    final admin2Set = await catalog.admin2(country.id);
    final admin2 =
        admin2Set?.locate(
          lon,
          lat,
          tolerance: _admin2Tolerance,
          where: (feature) => feature.parentId == admin1.id,
        ) ??
        admin2Set?.locate(lon, lat);
    if (admin2 != null) {
      ids.add(admin2.id);
    }
    return FootprintPlace(ids);
  }

  bool isVisited(String regionId) => _entriesByRegion.containsKey(regionId);

  int countFor(String regionId) => _entriesByRegion[regionId]?.length ?? 0;

  List<FootprintEntry> entriesIn(String regionId) =>
      _entriesByRegion[regionId] ?? const [];

  Iterable<RegionFeature> get visitedCountries =>
      world.features.where((feature) => isVisited(feature.id));

  /// Number of distinct deepest regions (cities where available).
  int get visitedPlaceCount => _leafRegionIds.length;
}
