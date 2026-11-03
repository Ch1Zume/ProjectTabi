import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../data/pilgrimage_repository.dart';
import '../plan/pilgrimage_models.dart';
import 'footprint_data.dart';
import 'footprint_preferences.dart';
import 'travel_photo_files.dart';

/// A travel photo waiting to be saved, with its place resolved.
class TravelPhotoDraft {
  TravelPhotoDraft({
    required this.bytes,
    required this.fileName,
    this.position,
    this.capturedAt,
    this.placeName = '',
    this.locatedFromExif = false,
  });

  final Uint8List bytes;
  final String fileName;
  LatLng? position;
  DateTime? capturedAt;

  /// Region path such as "京都府 · 宇治市", shown and stored as the point name.
  String placeName;
  final bool locatedFromExif;
}

/// Stores travel photos as travel-sourced points and visit records in a
/// dedicated plan, so they reuse plan storage, sync and desktop support.
class TravelJournal {
  TravelJournal(this._repository, {FootprintPreferences? preferences})
    : _preferences = preferences ?? FootprintPreferences.instance;

  final PilgrimageRepository _repository;
  final FootprintPreferences _preferences;

  static const _workTitle = '旅行';

  Future<PilgrimagePlan> ensurePlan() async {
    await _preferences.load();
    final plans = await _repository.loadPlans();
    for (final plan in plans) {
      if (isTravelPlan(plan, knownId: _preferences.travelPlanId)) {
        if (_preferences.travelPlanId != plan.id) {
          await _preferences.setTravelPlanId(plan.id);
        }
        return plan;
      }
    }
    final active = await _repository.loadActivePlan();
    final plan = await _repository.createPlan(
      name: travelPlanName,
      area: travelPlanArea,
    );
    // Creating a plan activates it; keep the pilgrimage plan in use.
    await _repository.setActivePlan(active.id);
    await _preferences.setTravelPlanId(plan.id);
    return plan;
  }

  /// Saves the located drafts and returns how many were saved.
  Future<int> save(List<TravelPhotoDraft> drafts) async {
    final located = [
      for (final draft in drafts)
        if (draft.position != null) draft,
    ];
    if (located.isEmpty) {
      return 0;
    }
    var plan = await ensurePlan();
    var work = _travelWork(plan);
    if (work == null) {
      plan = await _repository.addWorkToPlan(
        planId: plan.id,
        work: PilgrimageWork(
          id: 'travel-work-${plan.id}',
          title: _workTitle,
          subtitle: '',
          city: '',
          source: WorkSource.manual,
        ),
      );
      work = _travelWork(plan)!;
    }

    final stamp = DateTime.now().microsecondsSinceEpoch;
    final points = <PilgrimagePoint>[];
    final photoPaths = <String>[];
    for (var i = 0; i < located.length; i++) {
      final draft = located[i];
      final extension = travelPhotoExtension(draft.bytes);
      photoPaths.add(
        await storeTravelPhoto(
          draft.bytes,
          fileName: 'travel_${stamp}_$i.$extension',
        ),
      );
      final takenAt = draft.capturedAt;
      points.add(
        PilgrimagePoint(
          id: 'travel-$stamp-$i',
          work: work,
          name: draft.placeName.isEmpty ? '旅行地点' : draft.placeName,
          subtitle: draft.fileName,
          position: draft.position!,
          episodeLabel: '',
          referenceLabel: takenAt == null ? '' : _dateLabel(takenAt),
          source: PointSource.travel,
        ),
      );
    }
    await _repository.addPointsToPlan(planId: plan.id, points: points);

    var lastId = '';
    for (var i = 0; i < points.length; i++) {
      final record = await _repository.createVisitRecord(
        planId: plan.id,
        pointId: points[i].id,
        workId: work.id,
        workTitle: _workTitle,
        pointName: points[i].name,
        photoPath: photoPaths[i],
        referenceMode: 'travel',
        capturedAt: located[i].capturedAt,
      );
      // Record ids come from the clock, which only has millisecond
      // resolution in the desktop (web) build; never reuse one.
      assert(record.id != lastId);
      lastId = record.id;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return points.length;
  }

  Future<void> delete(FootprintEntry entry) async {
    await _repository.deleteVisitRecord(
      planId: entry.record.planId,
      recordId: entry.record.id,
    );
    await _repository.deletePointFromPlan(
      planId: entry.record.planId,
      pointId: entry.point.id,
    );
  }

  PilgrimageWork? _travelWork(PilgrimagePlan plan) {
    for (final work in plan.works) {
      if (work.title == _workTitle) {
        return work;
      }
    }
    return plan.works.isEmpty ? null : plan.works.first;
  }

  static String _dateLabel(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
