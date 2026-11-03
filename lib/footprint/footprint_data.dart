import 'package:latlong2/latlong.dart';

import '../data/pilgrimage_repository.dart';
import '../plan/pilgrimage_models.dart';
import 'footprint_preferences.dart';
import 'region_data.dart';

/// Ordinary travel photo or pilgrimage record.
enum FootprintKind { travel, pilgrimage }

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

  FootprintKind get kind => point.source == PointSource.travel
      ? FootprintKind.travel
      : FootprintKind.pilgrimage;
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

/// Name and area of the plan holding travel photos. Travel points are what
/// identify the plan; the markers only cover a freshly created empty one.
const travelPlanName = '旅行足迹';
const travelPlanArea = 'ProjectTabi 旅行足迹';

bool isTravelPlan(PilgrimagePlan plan, {String? knownId}) =>
    plan.id == knownId ||
    (plan.name == travelPlanName && plan.area == travelPlanArea) ||
    plan.points.any((point) => point.source == PointSource.travel);

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
    required this.allEntries,
    required this.unlocatedCount,
    required this.filter,
    required Map<String, FootprintPlace> places,
  }) : _places = places {
    for (final entry in allEntries) {
      if (!_matches(entry)) {
        continue;
      }
      entries.add(entry);
      final place = places[entry.record.id];
      if (place == null) {
        continue;
      }
      for (final id in place.regionIds) {
        (_entriesByRegion[id] ??= []).add(entry);
      }
      _leafRegionIds.add(place.deepestId);
    }
  }

  final RegionSet world;

  /// Every entry regardless of [filter], newest first.
  final List<FootprintEntry> allEntries;

  /// Entries shown under [filter], newest first.
  final List<FootprintEntry> entries = [];
  final int unlocatedCount;
  final FootprintFilter filter;
  final Map<String, FootprintPlace> _places;
  final Map<String, List<FootprintEntry>> _entriesByRegion = {};
  final Set<String> _leafRegionIds = {};

  /// Coastline simplification can push seaside points outside every
  /// polygon, so lookups fall back to the nearest region within these
  /// distances (degrees).
  static const _countryTolerance = 0.35;
  static const _admin1Tolerance = 0.2;
  static const _admin2Tolerance = 0.08;

  static Future<FootprintIndex> build(
    RegionCatalog catalog,
    FootprintSource source, {
    FootprintFilter filter = FootprintFilter.all,
  }) async {
    final world = await catalog.world();
    final places = <String, FootprintPlace>{};
    for (final entry in source.entries) {
      final place = await locate(catalog, world, entry.position);
      if (place != null) {
        places[entry.record.id] = place;
      }
    }
    return FootprintIndex._(
      world: world,
      allEntries: source.entries,
      unlocatedCount: source.unlocatedCount,
      filter: filter,
      places: places,
    );
  }

  /// The same entries under another filter, without locating them again.
  FootprintIndex filtered(FootprintFilter value) => value == filter
      ? this
      : FootprintIndex._(
          world: world,
          allEntries: allEntries,
          unlocatedCount: unlocatedCount,
          filter: value,
          places: _places,
        );

  bool _matches(FootprintEntry entry) => switch (filter) {
    FootprintFilter.all => true,
    FootprintFilter.travel => entry.kind == FootprintKind.travel,
    FootprintFilter.pilgrimage => entry.kind == FootprintKind.pilgrimage,
  };

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

  /// The record shown for a region: the user's pick when it is still in
  /// view, otherwise the newest one.
  FootprintEntry? representativeOf(String regionId, Map<String, String> picks) {
    final candidates = entriesIn(regionId);
    if (candidates.isEmpty) {
      return null;
    }
    final picked = picks[regionId];
    if (picked != null) {
      for (final entry in candidates) {
        if (entry.record.id == picked) {
          return entry;
        }
      }
    }
    return candidates.first;
  }

  Iterable<RegionFeature> get visitedCountries =>
      world.features.where((feature) => isVisited(feature.id));

  /// Number of distinct deepest regions (cities where available).
  int get visitedPlaceCount => _leafRegionIds.length;
}
