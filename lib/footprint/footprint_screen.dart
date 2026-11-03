import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme.dart';
import '../data/pilgrimage_repository.dart';
import '../plan/pilgrimage_models.dart';
import '../plan/pilgrimage_plan_controller.dart';
import '../records/visit_record_detail_screen.dart';
import '../records/visit_record_photo_stub.dart'
    if (dart.library.io) '../records/visit_record_photo_io.dart';
import '../widgets/image_viewer_screen.dart';
import 'country_colors.dart';
import 'footprint_data.dart';
import 'footprint_preferences.dart';
import 'globe_view.dart';
import 'region_data.dart';
import 'region_map_view.dart';
import 'travel_import_screen.dart';
import 'travel_journal.dart';
import 'travel_photo_files.dart';

/// Life footprint map: a globe of visited countries that drills down to
/// provinces, cities and finally the records on the real map.
class FootprintScreen extends StatefulWidget {
  const FootprintScreen({
    required this.isActive,
    required this.repository,
    required this.controller,
    required this.settings,
    super.key,
  });

  final bool isActive;
  final PilgrimageRepository repository;
  final PilgrimagePlanController controller;
  final AppSettings settings;

  @override
  State<FootprintScreen> createState() => _FootprintScreenState();
}

class _FootprintScreenState extends State<FootprintScreen> {
  final RegionCatalog _catalog = RegionCatalog();
  final GlobeCamera _globeCamera = GlobeCamera();
  final List<FootprintMapLevel> _levels = [];
  final FootprintPreferences _preferences = FootprintPreferences.instance;

  /// Index of every footprint; the map shows it under the chosen filter.
  FootprintIndex? _fullIndex;

  /// Snapshot of the representative photo picks, replaced on every change so
  /// the maps notice it.
  Map<String, String> _photoPicks = const {};
  Object? _error;
  bool _loading = false;
  bool _opening = false;
  bool _importing = false;
  bool _centeredOnFootprints = false;
  int _loadGeneration = 0;

  FootprintIndex? get _index => _fullIndex?.filtered(_preferences.filter);

  @override
  void initState() {
    super.initState();
    _preferences.addListener(_onPreferencesChanged);
    _preferences.load();
    if (widget.isActive) {
      _load();
    }
  }

  @override
  void didUpdateWidget(FootprintScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Records may have changed in other tabs; refresh when shown again.
    if (widget.isActive && !oldWidget.isActive) {
      _load();
    }
  }

  @override
  void dispose() {
    _preferences.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  void _onPreferencesChanged() {
    if (mounted) {
      setState(() => _photoPicks = Map.unmodifiable(_preferences.regionPhotos));
    }
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = await loadFootprintSource(widget.repository);
      final index = await FootprintIndex.build(_catalog, source);
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      if (!_centeredOnFootprints) {
        _centerGlobeOnFootprints(index);
      }
      setState(() {
        _fullIndex = index;
        _loading = false;
      });
    } catch (error, stackTrace) {
      debugPrint('Failed to load footprints: $error');
      debugPrint(stackTrace.toString());
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _centerGlobeOnFootprints(FootprintIndex index) {
    RegionFeature? busiest;
    for (final country in index.visitedCountries) {
      if (busiest == null || index.countFor(country.id) > index.countFor(busiest.id)) {
        busiest = country;
      }
    }
    if (busiest != null) {
      _globeCamera
        ..lon = busiest.label.longitude - 25
        ..lat = busiest.label.latitude.clamp(-50.0, 50.0) * 0.6;
    }
    _centeredOnFootprints = true;
  }

  Future<void> _enterCountry(RegionFeature country) async {
    await _open(() async {
      final world = _fullIndex!.world;
      final divisions = country.hasChildren
          ? await _catalog.admin1(country.id)
          : null;
      if (divisions == null || divisions.features.isEmpty) {
        return FootprintMapLevel(region: country);
      }
      final frame = country.bounds.expand(12);
      return FootprintMapLevel(
        region: country,
        children: divisions.features,
        context: [
          for (final other in world.features)
            if (other.id != country.id && other.bounds.overlaps(frame)) other,
        ],
        lines: divisions.lines,
      );
    });
  }

  Future<void> _enterChild(RegionFeature child) async {
    final parentLevel = _levels.last;
    final siblings = [
      for (final sibling in parentLevel.children)
        if (sibling.id != child.id) sibling,
    ];
    await _open(() async {
      if (child.level == RegionLevel.admin1 && child.hasChildren) {
        final cities = await _catalog.admin2(child.countryCode);
        final children = cities?.childrenOf(child.id).toList() ?? const [];
        if (children.isNotEmpty) {
          return FootprintMapLevel(
            region: child,
            children: children,
            context: siblings,
            lines: cities!.lines,
          );
        }
      }
      return FootprintMapLevel(region: child, context: siblings);
    });
  }

  Future<void> _open(Future<FootprintMapLevel> Function() build) async {
    if (_opening) {
      return;
    }
    _opening = true;
    try {
      final level = await build();
      if (mounted) {
        setState(() => _levels.add(level));
      }
    } finally {
      _opening = false;
    }
  }

  void _popTo(int depth) {
    if (depth < _levels.length) {
      setState(() => _levels.removeRange(depth, _levels.length));
    }
  }

  Future<void> _importTravelPhotos() async {
    if (_importing) {
      return;
    }
    setState(() => _importing = true);
    try {
      final photos = await pickTravelPhotos();
      if (photos.isEmpty || !mounted) {
        return;
      }
      final saved = await Navigator.of(context).push<int>(
        MaterialPageRoute(
          builder: (_) => TravelImportScreen(
            photos: photos,
            repository: widget.repository,
            catalog: _catalog,
            settings: widget.settings,
          ),
        ),
      );
      if (saved != null && saved > 0 && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已添加 $saved 张旅行照片')));
        await _load();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法读取照片：$error')));
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  Future<void> _openDisplaySettings() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (_) => _FootprintDisplaySheet(preferences: _preferences),
    );
  }

  Future<void> _pickRegionPhoto(RegionFeature region) async {
    final index = _index;
    if (index == null) {
      return;
    }
    final entries = index.entriesIn(region.id);
    final current = index.representativeOf(region.id, _photoPicks);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (context) => _RegionPhotoPickerSheet(
        region: region,
        entries: entries,
        selectedId: current?.record.id,
        hasManualPick: _photoPicks.containsKey(region.id),
        onSelect: (recordId) {
          Navigator.of(context).pop();
          _preferences.setRegionPhoto(region.id, recordId);
        },
      ),
    );
  }

  Future<void> _openEntries(String title, List<FootprintEntry> entries) async {
    if (entries.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (context) => _FootprintEntriesSheet(
        title: title,
        entries: entries,
        activePlanId: widget.controller.plan.id,
        travelColor: _preferences.travelColor,
        pilgrimageColor: _preferences.pilgrimageColor,
        onOpen: _openEntry,
        onDelete: _deleteTravelEntry,
      ),
    );
  }

  Future<void> _deleteTravelEntry(FootprintEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这张旅行照片？'),
        content: Text('“${entry.record.displayPointNameSnapshot}”的记录和地点会一起删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await TravelJournal(widget.repository).delete(entry);
    if (mounted) {
      await _load();
    }
  }

  Future<void> _openEntry(FootprintEntry entry) async {
    final controller = widget.controller;
    final record = entry.record;
    if (record.planId != controller.plan.id) {
      // Details and editing go through the active plan's controller; travel
      // photos and other plans only offer the photo.
      final path = resolveVisitRecordDisplayPhotoPath(record);
      if (path != null) {
        await ImageViewerScreen.show(context, filePath: path);
      }
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VisitRecordDetailScreen(
          record: record,
          point: controller.pointById(record.pointId),
          controller: controller,
          settings: widget.settings,
          onDelete: () => controller.deleteVisitRecord(record),
        ),
      ),
    );
    if (mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final index = _index;
    return PopScope(
      canPop: _levels.isEmpty || !widget.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _levels.isNotEmpty) {
          _popTo(_levels.length - 1);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          key: const ValueKey('footprint-app-bar'),
          toolbarHeight: AppTheme.appBarHeight,
          leading: _levels.isEmpty
              ? null
              : IconButton(
                  tooltip: '返回上一级',
                  onPressed: () => _popTo(_levels.length - 1),
                  icon: const Icon(LucideIcons.arrowLeft),
                ),
          title: const Text(
            '足迹',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
          ),
          actions: [
            IconButton(
              tooltip: '添加旅行照片',
              onPressed: _importing ? null : _importTravelPhotos,
              icon: const Icon(LucideIcons.imagePlus),
            ),
            IconButton(
              tooltip: '显示与颜色',
              onPressed: _openDisplaySettings,
              icon: const Icon(LucideIcons.palette),
            ),
            IconButton(
              tooltip: '刷新足迹',
              onPressed: _loading ? null : _load,
              icon: const Icon(LucideIcons.refreshCw),
            ),
            const SizedBox(width: 8),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _FilterBar(
                filter: _preferences.filter,
                travelColor: _preferences.travelColor,
                pilgrimageColor: _preferences.pilgrimageColor,
                onChanged: _preferences.setFilter,
              ),
            ),
          ),
        ),
        body: index == null
            ? _FootprintLoadState(
                loading: _loading || _error == null,
                error: _error,
                onRetry: _load,
              )
            : _buildMap(index),
      ),
    );
  }

  Widget _buildMap(FootprintIndex index) {
    final level = _levels.isEmpty ? null : _levels.last;
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: level == null
                ? GlobeView(
                    key: const ValueKey('footprint-globe'),
                    index: index,
                    camera: _globeCamera,
                    onEnterCountry: _enterCountry,
                  )
                : RegionMapView(
                    key: ValueKey('footprint-level-${level.region.id}'),
                    level: level,
                    index: index,
                    settings: widget.settings,
                    photoPicks: _photoPicks,
                    travelColor: _preferences.travelColor,
                    pilgrimageColor: _preferences.pilgrimageColor,
                    onEnterChild: _enterChild,
                    onLongPressRegion: _pickRegionPhoto,
                    onOpenEntries: (entries) => _openEntries(
                      entries.first.record.displayPointNameSnapshot,
                      entries,
                    ),
                  ),
          ),
        ),
        Positioned(
          left: 12,
          right: level == null ? 72 : 12,
          top: 8,
          child: level == null
              ? _GlobeSummary(index: index)
              : _Breadcrumbs(levels: _levels, onSelect: _popTo),
        ),
        if (level != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: _RegionSummaryCard(
              level: level,
              index: index,
              onOpenEntries: () => _openEntries(
                level.region.name,
                index.entriesIn(level.region.id),
              ),
            ),
          ),
        if (index.allEntries.isEmpty)
          Positioned(
            left: 16,
            right: 16,
            bottom: 72,
            child: _EmptyFootprintHint(onImport: _importTravelPhotos),
          ),
        if (_loading)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.travelColor,
    required this.pilgrimageColor,
    required this.onChanged,
  });

  final FootprintFilter filter;
  final Color travelColor;
  final Color pilgrimageColor;
  final ValueChanged<FootprintFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget dot(Color color) => Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<FootprintFilter>(
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
        segments: [
          const ButtonSegment(value: FootprintFilter.all, label: Text('全部')),
          ButtonSegment(
            value: FootprintFilter.travel,
            icon: dot(travelColor),
            label: const Text('旅行'),
          ),
          ButtonSegment(
            value: FootprintFilter.pilgrimage,
            icon: dot(pilgrimageColor),
            label: const Text('圣地巡礼'),
          ),
        ],
        selected: {filter},
        onSelectionChanged: (selection) => onChanged(selection.single),
      ),
    );
  }
}

class _FootprintDisplaySheet extends StatelessWidget {
  const _FootprintDisplaySheet({required this.preferences});

  final FootprintPreferences preferences;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '标点颜色',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '市级地图上，旅行照片和圣地巡礼记录用不同颜色的外圈区分。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _ColorRow(
              label: '旅行',
              selected: preferences.travelColor,
              onSelect: preferences.setTravelColor,
            ),
            const SizedBox(height: 12),
            _ColorRow(
              label: '圣地巡礼',
              selected: preferences.pilgrimageColor,
              onSelect: preferences.setPilgrimageColor,
            ),
            const SizedBox(height: 16),
            Text(
              '在国家或省级地图上长按已点亮的区域，可以更换它的代表照片。',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.label,
    required this.selected,
    required this.onSelect,
  });

  final String label;
  final Color selected;
  final ValueChanged<Color> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final color in footprintKindColorChoices)
                Semantics(
                  button: true,
                  selected: color == selected,
                  label: '$label颜色',
                  child: GestureDetector(
                    onTap: () => onSelect(color),
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: color == selected
                              ? AppColors.textPrimary
                              : Colors.transparent,
                          width: 2.5,
                        ),
                      ),
                      child: color == selected
                          ? const Icon(
                              LucideIcons.check,
                              size: 16,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RegionPhotoPickerSheet extends StatelessWidget {
  const _RegionPhotoPickerSheet({
    required this.region,
    required this.entries,
    required this.selectedId,
    required this.hasManualPick,
    required this.onSelect,
  });

  final RegionFeature region;
  final List<FootprintEntry> entries;
  final String? selectedId;
  final bool hasManualPick;

  /// Called with null to go back to the automatic choice.
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${region.name}的代表照片',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (hasManualPick)
                  TextButton(
                    onPressed: () => onSelect(null),
                    child: const Text('恢复自动'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final selected = entry.record.id == selectedId;
                return GestureDetector(
                  onTap: () => onSelect(entry.record.id),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? AppColors.accentDark : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: VisitRecordPhoto(
                        path: resolveVisitRecordDisplayPhotoPath(entry.record),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFootprintHint extends StatelessWidget {
  const _EmptyFootprintHint({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '还没有足迹。拍摄巡礼记录，或导入带位置的旅行照片来点亮地图。',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: onImport,
              icon: const Icon(LucideIcons.imagePlus, size: 18),
              label: const Text('导入'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FootprintLoadState extends StatelessWidget {
  const _FootprintLoadState({
    required this.loading,
    required this.error,
    required this.onRetry,
  });

  final bool loading;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.globe, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              '足迹地图加载失败',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(LucideIcons.refreshCw),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlobeSummary extends StatelessWidget {
  const _GlobeSummary({required this.index});

  final FootprintIndex index;

  @override
  Widget build(BuildContext context) {
    final countries = index.visitedCountries.length;
    final records = index.entries.length;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatChip(value: '$countries', label: '国家/地区'),
        _StatChip(value: '${index.visitedPlaceCount}', label: '城市'),
        _StatChip(value: '$records', label: '巡礼记录'),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: value,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              TextSpan(
                text: ' $label',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.levels, required this.onSelect});

  final List<FootprintMapLevel> levels;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final items = [
      ('地球', LucideIcons.globe),
      for (final level in levels) (level.region.name, null),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      reverse: true,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  LucideIcons.chevronRight,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
              ),
            ActionChip(
              avatar: items[i].$2 == null ? null : Icon(items[i].$2, size: 16),
              label: Text(items[i].$1),
              labelStyle: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: i == items.length - 1
                    ? FontWeight.w800
                    : FontWeight.w500,
              ),
              backgroundColor: AppColors.surface.withValues(alpha: 0.9),
              side: BorderSide(color: AppColors.border),
              onPressed: i == items.length - 1 ? null : () => onSelect(i),
            ),
          ],
        ],
      ),
    );
  }
}

class _RegionSummaryCard extends StatelessWidget {
  const _RegionSummaryCard({
    required this.level,
    required this.index,
    required this.onOpenEntries,
  });

  final FootprintMapLevel level;
  final FootprintIndex index;
  final VoidCallback onOpenEntries;

  @override
  Widget build(BuildContext context) {
    final region = level.region;
    final count = index.countFor(region.id);
    final color = countryColor(region.countryCode);
    final visitedChildren = level.children
        .where((child) => index.isVisited(child.id))
        .length;
    final detail = level.isLeaf
        ? (count > 0 ? '$count 条巡礼记录' : '这里还没有巡礼记录')
        : '已点亮 $visitedChildren / ${level.children.length} 个'
              '${_divisionName(level)} · $count 条记录';
    return Material(
      color: AppColors.surface,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: count > 0 ? color : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(color: color, width: 2),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    region.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    level.isLeaf ? detail : '$detail\n点击区域继续深入',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (count > 0)
              FilledButton.tonalIcon(
                onPressed: onOpenEntries,
                icon: const Icon(LucideIcons.images, size: 18),
                label: const Text('记录'),
              ),
          ],
        ),
      ),
    );
  }

  String _divisionName(FootprintMapLevel level) {
    final country = level.region.countryCode;
    final cityLevel = level.region.level == RegionLevel.admin1;
    return switch ((country, cityLevel)) {
      ('CHN', false) => '省级行政区',
      ('CHN', true) => '地级市',
      ('JPN', false) => '都道府县',
      ('JPN', true) => '市区町村',
      (_, false) => '一级行政区',
      (_, true) => '城市',
    };
  }
}

class _FootprintEntriesSheet extends StatelessWidget {
  const _FootprintEntriesSheet({
    required this.title,
    required this.entries,
    required this.activePlanId,
    required this.travelColor,
    required this.pilgrimageColor,
    required this.onOpen,
    required this.onDelete,
  });

  final String title;
  final List<FootprintEntry> entries;
  final String activePlanId;
  final Color travelColor;
  final Color pilgrimageColor;
  final Future<void> Function(FootprintEntry entry) onOpen;
  final Future<void> Function(FootprintEntry entry) onDelete;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '$title · ${entries.length} 条记录',
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final travel = entry.kind == FootprintKind.travel;
                  return _FootprintEntryTile(
                    entry: entry,
                    inActivePlan: entry.record.planId == activePlanId,
                    kindColor: travel ? travelColor : pilgrimageColor,
                    onTap: () async {
                      Navigator.of(context).pop();
                      await onOpen(entry);
                    },
                    onLongPress: travel
                        ? () async {
                            Navigator.of(context).pop();
                            await onDelete(entry);
                          }
                        : null,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FootprintEntryTile extends StatelessWidget {
  const _FootprintEntryTile({
    required this.entry,
    required this.inActivePlan,
    required this.kindColor,
    required this.onTap,
    this.onLongPress,
  });

  final FootprintEntry entry;
  final bool inActivePlan;
  final Color kindColor;
  final VoidCallback onTap;

  /// Only travel photos can be deleted here.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final record = entry.record;
    final date = record.capturedAt;
    final dateText =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final work = entry.kind == FootprintKind.travel
        ? '旅行照片 · 长按可删除'
        : record.displayWorkTitleSnapshot;
    return Material(
      color: AppColors.surfaceMuted,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 56,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: kindColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: VisitRecordPhoto(
                    path: resolveVisitRecordDisplayPhotoPath(record),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      record.displayPointNameSnapshot,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      work,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$dateText · ${entry.planName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                inActivePlan ? LucideIcons.chevronRight : LucideIcons.image,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
