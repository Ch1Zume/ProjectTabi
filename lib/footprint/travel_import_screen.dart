import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../app_theme.dart';
import '../data/pilgrimage_repository.dart';
import '../map/map_tile_config.dart';
import '../plan/pilgrimage_models.dart';
import 'footprint_data.dart';
import 'region_data.dart';
import 'travel_journal.dart';
import 'travel_photo_files.dart';
import 'travel_photo_metadata.dart';

/// Reviews picked travel photos, resolves their places and saves them.
/// Pops with the number of saved photos.
class TravelImportScreen extends StatefulWidget {
  const TravelImportScreen({
    required this.photos,
    required this.repository,
    required this.catalog,
    required this.settings,
    super.key,
  });

  final List<PickedTravelPhoto> photos;
  final PilgrimageRepository repository;
  final RegionCatalog catalog;
  final AppSettings settings;

  @override
  State<TravelImportScreen> createState() => _TravelImportScreenState();
}

class _TravelImportScreenState extends State<TravelImportScreen> {
  final List<TravelPhotoDraft> _drafts = [];
  bool _preparing = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    for (final photo in widget.photos) {
      final metadata = readTravelPhotoMetadata(photo.bytes);
      final draft = TravelPhotoDraft(
        bytes: photo.bytes,
        fileName: photo.name,
        position: metadata.position,
        capturedAt: metadata.capturedAt,
        locatedFromExif: metadata.position != null,
      );
      if (draft.position != null) {
        draft.placeName = await _placeName(draft.position!);
      }
      _drafts.add(draft);
      // Let the list fill in while large batches are read.
      if (mounted && _drafts.length % 8 == 0) {
        setState(() {});
      }
    }
    _drafts.sort((a, b) {
      final at = a.capturedAt;
      final bt = b.capturedAt;
      if (at == null || bt == null) {
        return at == null ? (bt == null ? 0 : 1) : -1;
      }
      return at.compareTo(bt);
    });
    if (mounted) {
      setState(() => _preparing = false);
    }
  }

  Future<String> _placeName(LatLng position) async {
    final world = await widget.catalog.world();
    final place = await FootprintIndex.locate(widget.catalog, world, position);
    if (place == null) {
      return '';
    }
    final ids = place.regionIds;
    final names = <String>[];
    if (ids.length > 1) {
      final admin1 = await widget.catalog.admin1(ids[0]);
      names.add(admin1?[ids[1]]?.name ?? '');
      if (ids.length > 2) {
        final admin2 = await widget.catalog.admin2(ids[0]);
        names.add(admin2?[ids[2]]?.name ?? '');
      }
    } else {
      names.add(world[ids[0]]?.name ?? '');
    }
    return names.where((name) => name.isNotEmpty).join(' · ');
  }

  Future<void> _pickLocation(TravelPhotoDraft draft) async {
    LatLng? hint = draft.position;
    if (hint == null) {
      // Photos of one trip are usually close together.
      for (final other in _drafts) {
        if (other.position != null) {
          hint = other.position;
          break;
        }
      }
    }
    final position = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => TravelLocationPickerScreen(
          photo: draft,
          initialPosition: hint,
          settings: widget.settings,
        ),
      ),
    );
    if (position == null || !mounted) {
      return;
    }
    final name = await _placeName(position);
    setState(() {
      draft
        ..position = position
        ..placeName = name;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final saved = await TravelJournal(widget.repository).save(_drafts);
      if (mounted) {
        Navigator.of(context).pop(saved);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final located = _drafts.where((draft) => draft.position != null).length;
    final missing = _drafts.length - located;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        toolbarHeight: AppTheme.appBarHeight,
        title: const Text(
          '导入旅行照片',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _preparing || _saving || located == 0 ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('保存 $located 张'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_preparing) const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(
                  missing == 0 ? LucideIcons.mapPinCheck : LucideIcons.mapPinOff,
                  size: 18,
                  color: missing == 0 ? AppColors.accentDark : AppColors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _preparing
                        ? '正在读取照片位置…'
                        : missing == 0
                        ? '${_drafts.length} 张照片均已定位'
                        : '$located 张已定位，$missing 张没有位置信息，点“选点”在地图上标出',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: _drafts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final draft = _drafts[index];
                return _DraftTile(
                  draft: draft,
                  onPickLocation: () => _pickLocation(draft),
                  onRemove: () => setState(() => _drafts.remove(draft)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({
    required this.draft,
    required this.onPickLocation,
    required this.onRemove,
  });

  final TravelPhotoDraft draft;
  final VoidCallback onPickLocation;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final located = draft.position != null;
    final date = draft.capturedAt;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                draft.bytes,
                width: 72,
                height: 72,
                fit: BoxFit.cover,
                cacheWidth: 216,
                errorBuilder: (_, _, _) => Container(
                  width: 72,
                  height: 72,
                  color: AppColors.surfaceMuted,
                  child: const Icon(LucideIcons.imageOff),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    located
                        ? (draft.placeName.isEmpty ? '海外或未知地区' : draft.placeName)
                        : '没有位置信息',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: located ? AppColors.textPrimary : AppColors.warning,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (date != null)
                        '${date.year}-${date.month.toString().padLeft(2, '0')}-'
                            '${date.day.toString().padLeft(2, '0')}',
                      if (located && !draft.locatedFromExif) '手动选点',
                      draft.fileName,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: onPickLocation,
              icon: const Icon(LucideIcons.mapPin, size: 16),
              label: Text(located ? '调整' : '选点'),
            ),
            IconButton(
              tooltip: '不导入这张',
              onPressed: onRemove,
              icon: const Icon(LucideIcons.x, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// Picks a location by moving the map under a fixed crosshair.
class TravelLocationPickerScreen extends StatefulWidget {
  const TravelLocationPickerScreen({
    required this.photo,
    required this.settings,
    this.initialPosition,
    super.key,
  });

  final TravelPhotoDraft photo;
  final AppSettings settings;
  final LatLng? initialPosition;

  @override
  State<TravelLocationPickerScreen> createState() =>
      _TravelLocationPickerScreenState();
}

class _TravelLocationPickerScreenState
    extends State<TravelLocationPickerScreen> {
  final MapController _mapController = MapController();

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.initialPosition;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: AppTheme.appBarHeight,
        title: const Text('选择拍摄地点'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_mapController.camera.center),
              child: const Text('确定'),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initial ?? const LatLng(35.0, 135.5),
              initialZoom: initial == null ? 5 : 14,
              maxZoom: widget.settings.mapMaxZoom.toDouble(),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onTap: (_, position) => _mapController.move(
                position,
                _mapController.camera.zoom,
              ),
            ),
            children: [configuredMapTileLayer(widget.settings)],
          ),
          IgnorePointer(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: Icon(
                  LucideIcons.mapPin,
                  size: 40,
                  color: AppColors.accentDark,
                ),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Material(
              color: AppColors.surface,
              elevation: 2,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Row(
                children: [
                  Image.memory(
                    widget.photo.bytes,
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                    cacheWidth: 216,
                    errorBuilder: (_, _, _) => const SizedBox(width: 72),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '拖动地图，让图钉对准拍摄地点，也可以直接点地图',
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
