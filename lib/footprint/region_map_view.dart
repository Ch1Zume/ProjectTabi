import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app_theme.dart';
import '../map/map_colors.dart';
import '../map/map_marker_clustering.dart';
import '../map/map_tile_config.dart';
import '../plan/pilgrimage_models.dart';
import '../records/visit_record_photo_stub.dart'
    if (dart.library.io) '../records/visit_record_photo_io.dart';
import 'country_colors.dart';
import 'footprint_data.dart';
import 'region_data.dart';
import 'region_photo_layer.dart';
import 'travel_photo_files.dart';

/// Insets that keep fitted regions clear of the breadcrumb and summary card.
const EdgeInsets footprintMapPadding = EdgeInsets.fromLTRB(20, 76, 20, 112);

/// Pale paper-like palette of the division maps: unvisited regions are
/// muted blocks separated by background-coloured borders.
class FootprintMapPalette {
  const FootprintMapPalette._({
    required this.background,
    required this.land,
    required this.contextLand,
    required this.border,
  });

  factory FootprintMapPalette.current() => AppColors.isDark
      ? const FootprintMapPalette._(
          background: Color(0xFF15171A),
          land: Color(0xFF2B2E33),
          contextLand: Color(0xFF212327),
          border: Color(0xFF15171A),
        )
      : const FootprintMapPalette._(
          background: Color(0xFFF6F4F0),
          land: Color(0xFFE4E0DA),
          contextLand: Color(0xFFEDEAE5),
          border: Color(0xFFFFFFFF),
        );

  final Color background;
  final Color land;
  final Color contextLand;
  final Color border;
}

/// A 2D step of the footprint map: a country or province split into its
/// divisions, or a city leaf shown on the real map with record markers.
class FootprintMapLevel {
  const FootprintMapLevel({
    required this.region,
    this.children = const [],
    this.context = const [],
    this.lines = const [],
  });

  final RegionFeature region;

  /// Divisions to pick from; empty for a city leaf.
  final List<RegionFeature> children;

  /// Neighbouring regions drawn faintly for orientation.
  final List<RegionFeature> context;

  /// Decorative lines such as the nine-dash line.
  final List<RegionRing> lines;

  bool get isLeaf => children.isEmpty;
}

class RegionMapView extends StatefulWidget {
  const RegionMapView({
    required this.level,
    required this.index,
    required this.settings,
    required this.photoPicks,
    required this.travelColor,
    required this.pilgrimageColor,
    required this.onEnterChild,
    required this.onOpenEntries,
    required this.onLongPressRegion,
    super.key,
  });

  final FootprintMapLevel level;
  final FootprintIndex index;
  final AppSettings settings;

  /// Record ids chosen as representative photos, keyed by region id.
  final Map<String, String> photoPicks;
  final Color travelColor;
  final Color pilgrimageColor;
  final ValueChanged<RegionFeature> onEnterChild;
  final ValueChanged<List<FootprintEntry>> onOpenEntries;
  final ValueChanged<RegionFeature> onLongPressRegion;

  @override
  State<RegionMapView> createState() => _RegionMapViewState();
}

class _RegionMapViewState extends State<RegionMapView>
    with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  late final AnimationController _flight = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  )..addListener(_onFlightTick);
  MapCamera? _flightFrom;
  MapCamera? _flightTo;
  bool _entering = false;

  late FootprintMapPalette _palette;
  late List<Polygon> _contextPolygons;
  late List<Polygon> _regionPolygons;
  late List<Polyline> _lines;
  late List<_PointEntries> _points;

  /// Decoded representative photos by record id. Regions whose photo is
  /// missing or still loading fall back to their colour.
  final Map<String, ImageInfo> _photos = {};
  final Set<String> _requestedPhotos = {};
  List<RegionPhotoFill> _photoFills = const [];

  @override
  void initState() {
    super.initState();
    _buildShapes();
  }

  @override
  void didUpdateWidget(RegionMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.level, widget.level) ||
        !identical(oldWidget.index, widget.index) ||
        oldWidget.photoPicks != widget.photoPicks ||
        oldWidget.travelColor != widget.travelColor ||
        oldWidget.pilgrimageColor != widget.pilgrimageColor) {
      _buildShapes();
    }
  }

  @override
  void dispose() {
    _flight.dispose();
    _mapController.dispose();
    for (final info in _photos.values) {
      info.dispose();
    }
    super.dispose();
  }

  RegionFeature get _region => widget.level.region;

  Color get _regionColor => countryColor(_region.countryCode);

  void _buildShapes() {
    final level = widget.level;
    final index = widget.index;
    final color = _regionColor;
    final palette = _palette = FootprintMapPalette.current();

    _contextPolygons = [
      for (final feature in level.context)
        ..._polygonsOf(
          feature,
          fill: palette.contextLand,
          border: palette.border,
          width: 0.8,
        ),
    ];

    if (level.isLeaf) {
      _regionPolygons = _polygonsOf(
        _region,
        fill: color.withValues(alpha: 0.06),
        border: color,
        width: 2.4,
      );
    } else {
      _regionPolygons = [
        for (final child in level.children)
          ..._polygonsOf(
            child,
            fill: index.isVisited(child.id)
                ? color.withValues(alpha: 0.8)
                : palette.land,
            border: palette.border,
            width: 1,
          ),
      ];
    }

    _lines = [
      for (final line in level.lines)
        Polyline(
          points: line.toLatLngs(),
          color: AppColors.textSecondary.withValues(alpha: 0.7),
          strokeWidth: 1.4,
        ),
    ];

    final grouped = <String, _PointEntries>{};
    if (level.isLeaf) {
      // Every record of the country, so panning past the city border still
      // shows neighbouring footprints.
      for (final entry in index.entriesIn(_region.countryCode)) {
        final key =
            '${entry.point.position.latitude.toStringAsFixed(5)},'
            '${entry.point.position.longitude.toStringAsFixed(5)}';
        (grouped[key] ??= _PointEntries(entry.point.position)).entries.add(
          entry,
        );
      }
    }
    _points = grouped.values.toList(growable: false);
    _updatePhotoFills();
  }

  /// Representative entry per visited division.
  Map<RegionFeature, FootprintEntry> get _representatives {
    final result = <RegionFeature, FootprintEntry>{};
    if (widget.level.isLeaf) {
      return result;
    }
    for (final child in widget.level.children) {
      final entry = widget.index.representativeOf(child.id, widget.photoPicks);
      if (entry != null) {
        result[child] = entry;
      }
    }
    return result;
  }

  void _updatePhotoFills() {
    final fills = <RegionPhotoFill>[];
    for (final MapEntry(key: region, value: entry)
        in _representatives.entries) {
      final info = _photos[entry.record.id];
      if (info != null) {
        fills.add(RegionPhotoFill(region: region, image: info.image));
      } else {
        _loadPhoto(entry);
      }
    }
    _photoFills = fills;
  }

  Future<void> _loadPhoto(FootprintEntry entry) async {
    final id = entry.record.id;
    if (!_requestedPhotos.add(id)) {
      return;
    }
    final path = resolveVisitRecordDisplayPhotoPath(entry.record);
    if (path == null) {
      return;
    }
    final provider = await loadRecordPhotoImage(path);
    if (provider == null || !mounted) {
      return;
    }
    // Region fills are small on screen; decoding full photos would waste
    // memory with dozens of regions.
    final stream = ResizeImage(
      provider,
      width: 720,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    ).resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!mounted) {
          info.dispose();
          return;
        }
        setState(() {
          _photos[id]?.dispose();
          _photos[id] = info.clone();
          info.dispose();
          _updatePhotoFills();
        });
      },
      onError: (_, _) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  List<Polygon> _polygonsOf(
    RegionFeature feature, {
    Color? fill,
    required Color border,
    required double width,
  }) {
    return [
      for (final polygon in feature.polygons)
        Polygon(
          points: polygon.exterior.toLatLngs(),
          holePointsList: [for (final hole in polygon.holes) hole.toLatLngs()],
          color: fill,
          borderColor: border,
          borderStrokeWidth: width,
        ),
    ];
  }

  void _onFlightTick() {
    final from = _flightFrom;
    final to = _flightTo;
    if (from == null || to == null) {
      return;
    }
    final t = Curves.easeInOutCubic.transform(_flight.value);
    _mapController.move(
      LatLng(
        from.center.latitude + (to.center.latitude - from.center.latitude) * t,
        from.center.longitude +
            (to.center.longitude - from.center.longitude) * t,
      ),
      from.zoom + (to.zoom - from.zoom) * t,
    );
  }

  Future<void> _flyTo(RegionFeature feature) async {
    final camera = _mapController.camera;
    _flightFrom = camera;
    _flightTo = CameraFit.bounds(
      bounds: fitBoundsOf(feature),
      padding: footprintMapPadding,
      maxZoom: widget.settings.mapMaxZoom.toDouble(),
    ).fit(camera);
    await _flight.forward(from: 0);
  }

  RegionFeature? _childAt(LatLng position) {
    for (final child in widget.level.children) {
      if (child.contains(position.longitude, position.latitude)) {
        return child;
      }
    }
    return null;
  }

  Future<void> _handleTap(LatLng position) async {
    if (widget.level.isLeaf || _entering) {
      return;
    }
    final hit = _childAt(position);
    if (hit == null) {
      return;
    }
    _entering = true;
    await _flyTo(hit);
    _entering = false;
    if (mounted) {
      widget.onEnterChild(hit);
    }
  }

  void _handleLongPress(LatLng position) {
    final hit = widget.level.isLeaf ? null : _childAt(position);
    if (hit != null && widget.index.isVisited(hit.id)) {
      widget.onLongPressRegion(hit);
    }
  }

  @override
  Widget build(BuildContext context) {
    final level = widget.level;
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCameraFit: CameraFit.bounds(
          bounds: fitBoundsOf(level.region),
          padding: footprintMapPadding,
          maxZoom: widget.settings.mapMaxZoom.toDouble(),
        ),
        backgroundColor: level.isLeaf
            ? AppColors.surfaceMuted
            : _palette.background,
        minZoom: 1.5,
        maxZoom: widget.settings.mapMaxZoom.toDouble(),
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onTap: (_, position) => _handleTap(position),
        onLongPress: (_, position) => _handleLongPress(position),
      ),
      children: [
        if (level.isLeaf) configuredMapTileLayer(widget.settings),
        if (_contextPolygons.isNotEmpty && !level.isLeaf)
          PolygonLayer(polygons: _contextPolygons, simplificationTolerance: 0),
        PolygonLayer(polygons: _regionPolygons, simplificationTolerance: 0),
        if (_photoFills.isNotEmpty)
          RegionPhotoLayer(fills: _photoFills, borderColor: _palette.border),
        if (_lines.isNotEmpty) PolylineLayer(polylines: _lines),
        if (level.isLeaf)
          _RecordMarkerLayer(
            points: _points,
            travelColor: widget.travelColor,
            pilgrimageColor: widget.pilgrimageColor,
            onOpenEntries: widget.onOpenEntries,
          )
        else
          _RegionLabelLayer(
            children: level.children,
            index: widget.index,
            color: _regionColor,
            photoRegionIds: {for (final fill in _photoFills) fill.region.id},
          ),
      ],
    );
  }
}

LatLngBounds fitBoundsOf(RegionFeature feature) {
  final bounds = feature.mainBounds;
  return LatLngBounds(
    LatLng(bounds.south, bounds.west),
    LatLng(bounds.north, bounds.east),
  );
}

class _RegionLabelLayer extends StatelessWidget {
  const _RegionLabelLayer({
    required this.children,
    required this.index,
    required this.color,
    required this.photoRegionIds,
  });

  final List<RegionFeature> children;
  final FootprintIndex index;
  final Color color;

  /// Regions showing a photo carry no label, like a photo collage map.
  final Set<String> photoRegionIds;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final markers = <Marker>[];
    for (final child in children) {
      if (photoRegionIds.contains(child.id)) {
        continue;
      }
      final visited = index.isVisited(child.id);
      final width = _screenWidth(camera, child);
      if (width <= child.name.length * 13 + 40) {
        // A full label would hide a small region's fill; show only the
        // count, and nothing once even that would cover the region.
        if (visited && width >= 30) {
          markers.add(
            Marker(
              point: child.label,
              width: 24,
              height: 24,
              child: IgnorePointer(
                child: Center(
                  child: _RegionCountDot(
                    count: index.countFor(child.id),
                    color: color,
                  ),
                ),
              ),
            ),
          );
        }
        continue;
      }
      markers.add(
        Marker(
          point: child.label,
          width: 120,
          height: 28,
          child: IgnorePointer(
            child: Center(
              child: _RegionLabel(
                name: child.name,
                count: index.countFor(child.id),
                color: color,
              ),
            ),
          ),
        ),
      );
    }
    return MarkerLayer(markers: markers);
  }

  /// On-screen width of a region; names only appear once it fits them.
  double _screenWidth(MapCamera camera, RegionFeature feature) {
    final bounds = feature.mainBounds;
    final west = camera.projectAtZoom(LatLng(feature.label.latitude, bounds.west));
    final east = camera.projectAtZoom(LatLng(feature.label.latitude, bounds.east));
    return (east.dx - west.dx).abs();
  }
}

class _RegionCountDot extends StatelessWidget {
  const _RegionCountDot({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0,
        ),
      ),
    );
  }
}

class _RegionLabel extends StatelessWidget {
  const _RegionLabel({
    required this.name,
    required this.count,
    required this.color,
  });

  final String name;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final visited = count > 0;
    final text = Text(
      visited ? '$name · $count' : name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: visited ? AppColors.foregroundOn(color) : AppColors.textSecondary,
        fontSize: visited ? 12 : 11,
        fontWeight: visited ? FontWeight.w800 : FontWeight.w600,
        letterSpacing: 0,
      ),
    );
    if (!visited) {
      return text;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.85)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: text,
      ),
    );
  }
}

class _PointEntries {
  _PointEntries(this.position);

  final LatLng position;
  final List<FootprintEntry> entries = [];
}

class _RecordMarkerLayer extends StatelessWidget {
  const _RecordMarkerLayer({
    required this.points,
    required this.travelColor,
    required this.pilgrimageColor,
    required this.onOpenEntries,
  });

  final List<_PointEntries> points;
  final Color travelColor;
  final Color pilgrimageColor;
  final ValueChanged<List<FootprintEntry>> onOpenEntries;

  Color _colorOf(FootprintEntry entry) =>
      entry.kind == FootprintKind.travel ? travelColor : pilgrimageColor;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final controller = MapController.of(context);
    final clusters = clusterMapMarkers<_PointEntries>(
      items: points,
      positionOf: (point) => point.position,
      camera: camera,
      radiusPixels: 44,
    );
    return MarkerLayer(
      markers: [
        for (final cluster in clusters)
          if (cluster.items.length == 1)
            Marker(
              point: cluster.position,
              width: 52,
              height: 52,
              child: _RecordPhotoMarker(
                entries: cluster.items.single.entries,
                color: _colorOf(cluster.items.single.entries.first),
                onTap: () => onOpenEntries(cluster.items.single.entries),
              ),
            )
          else
            Marker(
              point: cluster.position,
              width: 48,
              height: 48,
              child: MapMarkerClusterBadge(
                count: cluster.items.fold(
                  0,
                  (sum, point) => sum + point.entries.length,
                ),
                opensPointBrowser: isAtMaximumMapZoom(camera),
                onTap: () {
                  if (isAtMaximumMapZoom(camera)) {
                    onOpenEntries([
                      for (final point in cluster.items) ...point.entries,
                    ]);
                  } else {
                    controller.move(
                      cluster.position,
                      math.min(camera.zoom + 2, camera.maxZoom ?? 18),
                    );
                  }
                },
              ),
            ),
      ],
    );
  }
}

class _RecordPhotoMarker extends StatelessWidget {
  const _RecordPhotoMarker({
    required this.entries,
    required this.color,
    required this.onTap,
  });

  final List<FootprintEntry> entries;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final latest = entries.first;
    return Semantics(
      button: true,
      label: '${latest.record.displayPointNameSnapshot}，${entries.length} 条记录',
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 46,
              height: 46,
              margin: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: color,
                    spreadRadius: 3,
                  ),
                  const BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: ClipOval(
                child: VisitRecordPhoto(
                  path: resolveVisitRecordDisplayPhotoPath(latest.record),
                ),
              ),
            ),
            if (entries.length > 1)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: MapColors.accent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                  child: Text(
                    '${entries.length}',
                    style: TextStyle(
                      color: MapColors.onAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
