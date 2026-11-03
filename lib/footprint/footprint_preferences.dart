import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../sync/sync_platform.dart';

/// Which kinds of footprints the map shows.
enum FootprintFilter { all, travel, pilgrimage }

/// Selectable marker colors for the two kinds of footprints.
const List<Color> footprintKindColorChoices = [
  Color(0xFF2F80ED),
  Color(0xFF16A085),
  Color(0xFF27AE60),
  Color(0xFFF2994A),
  Color(0xFFEB5757),
  Color(0xFFF45B9A),
  Color(0xFF9B51E0),
  Color(0xFF4F4F4F),
];

const Color _defaultTravelColor = Color(0xFF2F80ED);
const Color _defaultPilgrimageColor = Color(0xFFF45B9A);

/// Footprint map preferences. They belong to this device and are not synced.
class FootprintPreferences extends ChangeNotifier {
  FootprintPreferences._();
  static final instance = FootprintPreferences._();

  static const _storeKey = 'footprint_preferences';

  FootprintFilter filter = FootprintFilter.all;
  Color travelColor = _defaultTravelColor;
  Color pilgrimageColor = _defaultPilgrimageColor;

  /// Record id chosen as the representative photo of a region.
  final Map<String, String> regionPhotos = {};

  /// Id of the travel journal plan created on this device.
  String? travelPlanId;

  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final data =
          jsonDecode(await syncStoreRead(_storeKey) ?? '{}') as Map<String, Object?>;
      filter = FootprintFilter.values.firstWhere(
        (value) => value.name == data['filter'],
        orElse: () => FootprintFilter.all,
      );
      travelColor = _color(data['travelColor']) ?? _defaultTravelColor;
      pilgrimageColor =
          _color(data['pilgrimageColor']) ?? _defaultPilgrimageColor;
      final photos = data['regionPhotos'];
      if (photos is Map) {
        regionPhotos
          ..clear()
          ..addAll({
            for (final entry in photos.entries)
              if (entry.key is String && entry.value is String)
                entry.key as String: entry.value as String,
          });
      }
      travelPlanId = data['travelPlanId'] as String?;
    } catch (_) {
      // Missing or unreadable preferences use the defaults.
    }
    notifyListeners();
  }

  static Color? _color(Object? value) =>
      value is int ? Color(value) : null;

  Future<void> setFilter(FootprintFilter value) =>
      _update(() => filter = value);

  Future<void> setTravelColor(Color value) =>
      _update(() => travelColor = value);

  Future<void> setPilgrimageColor(Color value) =>
      _update(() => pilgrimageColor = value);

  Future<void> setRegionPhoto(String regionId, String? recordId) => _update(() {
    if (recordId == null) {
      regionPhotos.remove(regionId);
    } else {
      regionPhotos[regionId] = recordId;
    }
  });

  Future<void> setTravelPlanId(String id) => _update(() => travelPlanId = id);

  Future<void> _update(VoidCallback change) async {
    await load();
    change();
    notifyListeners();
    final encoded = jsonEncode({
      'filter': filter.name,
      'travelColor': travelColor.toARGB32(),
      'pilgrimageColor': pilgrimageColor.toARGB32(),
      'regionPhotos': regionPhotos,
      'travelPlanId': ?travelPlanId,
    });
    final write = _writes.then((_) => syncStoreWrite(_storeKey, encoded));
    _writes = write.catchError((Object _) {});
    await write;
  }
}
