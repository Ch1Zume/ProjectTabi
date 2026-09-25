import 'dart:async';
import '../update/update_activity.dart';
import '../data/pilgrimage_repository.dart';
import '../data/sample_pilgrimage_repository.dart';
import '../plan/pilgrimage_models.dart';
import 'sync_repository.dart';
import 'sync_platform.dart';

/// Serialize repository access while syncing, including already-running cache writes.
/// The sync's own zone may re-enter; other callers wait and apply their edits afterwards.
class SyncGuardRepository implements PilgrimageRepository, SyncRepository {
  SyncGuardRepository(this.delegate);
  final PilgrimageRepository delegate;
  static final _zoneKey = Object();
  Future<void> _tail = Future.value();
  bool get inExclusiveSync => identical(Zone.current[_zoneKey], this);
  Future<T> _enqueue<T>(Future<T> Function() action) {
    UpdateActivity.begin();
    final result = Completer<T>();
    final previous = _tail;
    _tail = () async {
      await previous;
      try {
        result.complete(await action());
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        UpdateActivity.end();
      }
    }();
    return result.future;
  }

  Future<T> _access<T>(Future<T> Function() action) =>
      inExclusiveSync ? action() : _enqueue(action);
  Future<T> _edit<T>(Future<T> Function() action) => _access(() async {
    final result = await action();
    try {
      await syncStoreWrite(
        'local_changed_at',
        DateTime.now().toUtc().toIso8601String(),
      );
    } on Exception {
      // The repository already committed. A missing timestamp must not undo it.
    }
    return result;
  });
  Future<T> exclusive<T>(Future<T> Function() action) =>
      _enqueue(() => runZoned(action, zoneValues: {_zoneKey: this}));
  @override
  Future<void> replaceSyncSnapshot(SamplePilgrimageRepositorySnapshot state) =>
      _access(() => (delegate as SyncRepository).replaceSyncSnapshot(state));
  @override
  Future<List<PilgrimagePlan>> loadPlans() =>
      _access(() => delegate.loadPlans());

  @override
  Future<PilgrimagePlan> loadActivePlan() =>
      _access(() => delegate.loadActivePlan());

  @override
  Future<AppSettings> loadAppSettings() =>
      _access(() => delegate.loadAppSettings());

  @override
  Future<List<PilgrimageVisitRecord>> loadVisitRecords(String planId) =>
      _access(() => delegate.loadVisitRecords(planId));

  @override
  Future<void> setActivePlan(String id) =>
      _access(() => delegate.setActivePlan(id));

  @override
  Future<void> reorderPlans({required List<String> orderedPlanIds}) =>
      _edit(() => delegate.reorderPlans(orderedPlanIds: orderedPlanIds));

  @override
  Future<PilgrimagePlan> createPlan({
    required String name,
    required String area,
  }) => _edit(() => delegate.createPlan(name: name, area: area));

  @override
  Future<PilgrimagePlan> importPlanPackage({
    required PilgrimagePlan plan,
    required List<PilgrimageVisitRecord> visitRecords,
  }) => _edit(
    () => delegate.importPlanPackage(plan: plan, visitRecords: visitRecords),
  );

  @override
  Future<PilgrimagePlan> renamePlan({
    required String planId,
    required String name,
  }) => _edit(() => delegate.renamePlan(planId: planId, name: name));

  @override
  Future<PilgrimagePlan> updatePlanInfo({
    required String planId,
    required String name,
    required String area,
  }) => _edit(
    () => delegate.updatePlanInfo(planId: planId, name: name, area: area),
  );

  @override
  Future<PilgrimagePlan> updatePlanMemo({
    required String planId,
    required String memo,
  }) => _edit(() => delegate.updatePlanMemo(planId: planId, memo: memo));

  @override
  Future<PilgrimagePlan> addPointToPlan({
    required String planId,
    required PilgrimagePoint point,
  }) => _edit(() => delegate.addPointToPlan(planId: planId, point: point));

  @override
  Future<PilgrimagePlan> addPointsToPlan({
    required String planId,
    required List<PilgrimagePoint> points,
  }) => _edit(() => delegate.addPointsToPlan(planId: planId, points: points));

  @override
  Future<PilgrimagePlan> updatePointInPlan({
    required String planId,
    required PilgrimagePoint point,
  }) => _edit(() => delegate.updatePointInPlan(planId: planId, point: point));

  @override
  Future<PilgrimagePlan> updatePointImageCache({
    required String planId,
    required String pointId,
    String? referenceThumbnailPath,
    String? referenceFullImagePath,
  }) => _access(
    () => delegate.updatePointImageCache(
      planId: planId,
      pointId: pointId,
      referenceThumbnailPath: referenceThumbnailPath,
      referenceFullImagePath: referenceFullImagePath,
    ),
  );

  @override
  Future<PilgrimagePlan> updatePointImageCaches({
    required String planId,
    required Map<String, PointImageCacheUpdate> updatesByPointId,
  }) => _access(
    () => delegate.updatePointImageCaches(
      planId: planId,
      updatesByPointId: updatesByPointId,
    ),
  );

  @override
  Future<PilgrimagePlan> addWorkToPlan({
    required String planId,
    required PilgrimageWork work,
  }) => _edit(() => delegate.addWorkToPlan(planId: planId, work: work));

  @override
  Future<PilgrimagePlan> createPlanGroup({
    required String planId,
    required PilgrimagePlanGroup group,
  }) => _edit(() => delegate.createPlanGroup(planId: planId, group: group));

  @override
  Future<PilgrimagePlan> renamePlanGroup({
    required String planId,
    required String groupId,
    required String name,
  }) => _edit(
    () =>
        delegate.renamePlanGroup(planId: planId, groupId: groupId, name: name),
  );

  @override
  Future<PilgrimagePlan> updatePlanGroup({
    required String planId,
    required PilgrimagePlanGroup group,
  }) => _edit(() => delegate.updatePlanGroup(planId: planId, group: group));

  @override
  Future<PilgrimagePlan> deletePlanGroup({
    required String planId,
    required String groupId,
  }) => _edit(() => delegate.deletePlanGroup(planId: planId, groupId: groupId));

  @override
  Future<PilgrimagePlan> movePointsToGroup({
    required String planId,
    required Set<String> pointIds,
    required String? groupId,
  }) => _edit(
    () => delegate.movePointsToGroup(
      planId: planId,
      pointIds: pointIds,
      groupId: groupId,
    ),
  );

  @override
  Future<PilgrimagePlan> deleteWorkFromPlan({
    required String planId,
    required String workId,
  }) =>
      _edit(() => delegate.deleteWorkFromPlan(planId: planId, workId: workId));

  @override
  Future<PilgrimagePlan> deletePointFromPlan({
    required String planId,
    required String pointId,
  }) => _edit(
    () => delegate.deletePointFromPlan(planId: planId, pointId: pointId),
  );

  @override
  Future<PilgrimagePlan> deletePointsFromPlan({
    required String planId,
    required Set<String> pointIds,
  }) => _edit(
    () => delegate.deletePointsFromPlan(planId: planId, pointIds: pointIds),
  );

  @override
  Future<PilgrimagePlan> reorderPoints({
    required String planId,
    required List<String> pointIds,
  }) => _edit(() => delegate.reorderPoints(planId: planId, pointIds: pointIds));

  @override
  Future<PilgrimagePlan> reorderGroupPoints({
    required String planId,
    required String groupId,
    required List<String> pointIds,
  }) => _edit(
    () => delegate.reorderGroupPoints(
      planId: planId,
      groupId: groupId,
      pointIds: pointIds,
    ),
  );

  @override
  Future<void> setCurrentPoint({
    required String planId,
    required String pointId,
  }) =>
      _access(() => delegate.setCurrentPoint(planId: planId, pointId: pointId));

  @override
  Future<void> setCurrentGroup({
    required String planId,
    required String? groupId,
  }) =>
      _access(() => delegate.setCurrentGroup(planId: planId, groupId: groupId));

  @override
  Future<void> completePoint({
    required String planId,
    required String pointId,
    required String? nextCurrentPointId,
  }) => _edit(
    () => delegate.completePoint(
      planId: planId,
      pointId: pointId,
      nextCurrentPointId: nextCurrentPointId,
    ),
  );

  @override
  Future<void> completePoints({
    required String planId,
    required Set<String> pointIds,
  }) =>
      _edit(() => delegate.completePoints(planId: planId, pointIds: pointIds));

  @override
  Future<void> reopenPoint({required String planId, required String pointId}) =>
      _edit(() => delegate.reopenPoint(planId: planId, pointId: pointId));

  @override
  Future<void> reopenPoints({
    required String planId,
    required Set<String> pointIds,
  }) => _edit(() => delegate.reopenPoints(planId: planId, pointIds: pointIds));

  @override
  Future<PilgrimageVisitRecord> createVisitRecord({
    required String planId,
    required String pointId,
    required String workId,
    String? workTitle,
    String? workSubtitle,
    String? pointName,
    String? pointSubtitle,
    required String photoPath,
    String? referenceImagePath,
    String? referenceImageUrl,
    required String referenceMode,
    DateTime? capturedAt,
  }) => _edit(
    () => delegate.createVisitRecord(
      planId: planId,
      pointId: pointId,
      workId: workId,
      workTitle: workTitle,
      workSubtitle: workSubtitle,
      pointName: pointName,
      pointSubtitle: pointSubtitle,
      photoPath: photoPath,
      referenceImagePath: referenceImagePath,
      referenceImageUrl: referenceImageUrl,
      referenceMode: referenceMode,
      capturedAt: capturedAt,
    ),
  );

  @override
  Future<PilgrimageVisitRecord> updateVisitRecordColorGrading({
    required String planId,
    required String recordId,
    required String originalPhotoPath,
    required String gradedPhotoPath,
    required String colorGradingMode,
    required String colorGradingParamsJson,
    required double colorGradingIntensity,
  }) => _edit(
    () => delegate.updateVisitRecordColorGrading(
      planId: planId,
      recordId: recordId,
      originalPhotoPath: originalPhotoPath,
      gradedPhotoPath: gradedPhotoPath,
      colorGradingMode: colorGradingMode,
      colorGradingParamsJson: colorGradingParamsJson,
      colorGradingIntensity: colorGradingIntensity,
    ),
  );

  @override
  Future<PilgrimageVisitRecord> clearVisitRecordColorGrading({
    required String planId,
    required String recordId,
  }) => _edit(
    () => delegate.clearVisitRecordColorGrading(
      planId: planId,
      recordId: recordId,
    ),
  );

  @override
  Future<void> deleteVisitRecord({
    required String planId,
    required String recordId,
  }) => _edit(
    () => delegate.deleteVisitRecord(planId: planId, recordId: recordId),
  );

  @override
  Future<void> deletePlan(String id) => _edit(() => delegate.deletePlan(id));

  @override
  Future<void> saveAppSettings(AppSettings settings) =>
      _access(() => delegate.saveAppSettings(settings));
}
