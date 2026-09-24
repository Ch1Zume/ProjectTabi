import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../data/pilgrimage_repository.dart';
import '../data/sample_pilgrimage_repository.dart';
import '../desktop/desktop_repository_state.dart';
import '../plan_transfer/plan_export_asset_stub.dart'
    if (dart.library.io) '../plan_transfer/plan_export_asset_io.dart';
import 'sync_merge.dart';

const syncImageFields = {
  'photoPath',
  'originalPhotoPath',
  'gradedPhotoPath',
  'referenceImagePath',
  'referenceThumbnailPath',
  'referenceFullImagePath',
};
final syncHashPattern = RegExp(r'^sync:([a-f0-9]{64})$');

class SyncAssetReadException implements Exception {
  const SyncAssetReadException({
    required this.context,
    required this.field,
    required this.path,
    this.reason = '文件不存在、没有读取权限，或文件为空。',
  });
  final String context;
  final String field;
  final String path;
  final String reason;

  @override
  String toString() {
    const labels = {
      'photoPath': '拍摄照片',
      'originalPhotoPath': '调色原图',
      'gradedPhotoPath': '调色结果',
      'referenceImagePath': '拍摄时的参考图',
      'referenceThumbnailPath': '参考缩略图',
      'referenceFullImagePath': '完整参考图',
    };
    final name = path.replaceAll(r'\', '/').split('/').last;
    return '无法读取${labels[field] ?? '图片'}：$name\n'
        '$context\n$reason\n文件路径：$path\n'
        '请检查这条记录，或重新导入包含图片的备份；请恢复后重试。';
  }
}

class CapturedSyncSnapshot {
  const CapturedSyncSnapshot(this.data, this.localJson, this.assets);
  final SyncJson data;
  final String localJson;
  final Map<String, String> assets;
}

Future<String> captureLocalJson(PilgrimageRepository repository) async {
  final plans = await repository.loadPlans();
  final active = await repository.loadActivePlan();
  final settings = await repository.loadAppSettings();
  final records = await Future.wait(
    plans.map((p) => repository.loadVisitRecords(p.id)),
  );
  return encodeDesktopRepositoryState(
    SamplePilgrimageRepositorySnapshot(
      plans: plans,
      visitRecords: records.expand((r) => r).toList(),
      settings: settings,
      activePlanId: active.id,
    ),
  );
}

Future<List<int>> readSyncImage(String path) async {
  List<int>? bytes;
  try {
    bytes = await readExportAssetBytes(path, preserveImageBytes: true);
  } on Exception {
    throw SyncAssetReadException(
      context: '上传前重新读取图片', field: 'photoPath', path: path,
      reason: '读取文件失败，请检查文件是否被移动、占用或撤销访问权限。',
    );
  }
  if (bytes == null || bytes.isEmpty || bytes.length > 128 * 1024 * 1024) {
    throw SyncAssetReadException(
      context: '上传前重新读取图片', field: 'photoPath', path: path,
      reason: bytes != null && bytes.length > 128 * 1024 * 1024
          ? '单张图片超过 128 MiB。' : '文件不存在、不可读取或为空。',
    );
  }
  return bytes;
}

Future<CapturedSyncSnapshot> captureSyncSnapshot(
  PilgrimageRepository repository, {
  bool tolerateMissingAssets = false,
}) async {
  final local = await captureLocalJson(repository);
  final json = jsonDecode(local) as Map<String, dynamic>;
  final assets = <String, String>{};
  final seenPaths = <String, String>{};
  final unavailable = <String>{};
  final planNames = {
    for (final plan in json['plans'] as List) (plan as Map)['id']: plan['name'],
  };
  final pointNames = {
    for (final plan in json['plans'] as List)
      for (final point in (plan as Map)['points'] as List)
        '${plan['id']}/${(point as Map)['id']}': point['name'],
  };

  String describe(Map value, String parent) {
    if (value.containsKey('plans')) {
      return parent;
    }
    if (value.containsKey('points') && value.containsKey('works')) {
      return '计划「${value['name'] ?? value['id']}」';
    }
    if (value.containsKey('photoPath')) {
      final point =
          value['pointName'] ??
          pointNames['${value['planId']}/${value['pointId']}'] ??
          value['pointId'];
      return '计划「${planNames[value['planId']] ?? value['planId']}」 / '
          '记录「$point」\n拍摄时间：${value['capturedAt']}';
    }
    if (value.containsKey('latitude') && value.containsKey('workId')) {
      return '$parent / 点位「${value['name'] ?? value['id']}」';
    }
    return parent;
  }

  bool hasRemoteReference(Map value) {
    final url = value['referenceImageUrl'];
    final uri = url is String ? Uri.tryParse(url) : null;
    return uri != null &&
        {'https', 'http'}.contains(uri.scheme) &&
        uri.host.isNotEmpty;
  }

  Future<String?> imageHash(String path, String context, String field) async {
    if (seenPaths.containsKey(path)) {
      return seenPaths[path];
    }
    if (unavailable.contains(path)) {
      return null;
    }
    List<int>? bytes;
    try {
      bytes = await readExportAssetBytes(path, preserveImageBytes: true);
    } on Exception {
      // Surface the affected record and field, not an opaque filesystem error.
      unavailable.add(path);
      return null;
    }
    if (bytes == null || bytes.isEmpty) {
      unavailable.add(path);
      return null;
    }
    if (bytes.length > 128 * 1024 * 1024) {
      if (tolerateMissingAssets) return null;
      throw SyncAssetReadException(
        context: context,
        field: field,
        path: path,
        reason: '单张图片超过 128 MiB。',
      );
    }
    final hash = sha256.convert(bytes).toString();
    final uri = Uri.tryParse(path);
    assets[hash] = uri?.scheme == 'file' ? uri!.toFilePath() : path;
    seenPaths[path] = hash;
    return hash;
  }

  Future<Object?> portable(Object? value, [String parent = '本地数据']) async {
    if (value is Map) {
      final context = describe(value, parent);
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key as String;
        final v = entry.value;
        if (syncImageFields.contains(key) && v is String && v.isNotEmpty) {
          var hash = await imageHash(v, context, key);
          // A thumbnail is derived; the matching full reference preserves its content.
          if (hash == null && key == 'referenceThumbnailPath') {
            final full = value['referenceFullImagePath'];
            if (full is String && full.isNotEmpty) {
              hash = await imageHash(full, context, 'referenceFullImagePath');
            }
          }
          if (hash == null) {
            if (tolerateMissingAssets ||
                (key.startsWith('reference') && hasRemoteReference(value))) {
              result[key] = null;
              continue;
            }
            throw SyncAssetReadException(context: context, field: key, path: v);
          }
          result[key] = 'sync:$hash';
        } else if ({'createdAt', 'updatedAt', 'capturedAt'}.contains(key) &&
            v is String) {
          result[key] = DateTime.parse(v).toUtc().toIso8601String();
        } else {
          result[key] = await portable(v, context);
        }
      }
      return result;
    }
    if (value is List) {
      final result = <Object?>[];
      for (final item in value) {
        result.add(await portable(item, parent));
      }
      return result;
    }
    return value;
  }

  final converted = await portable(json) as Map<String, Object?>;
  Map<String, Object?> keyed(List list) => {
    for (var i = 0; i < list.length; i++)
      (list[i] as Map)['id'] as String: {
        ...Map<String, Object?>.from(list[i] as Map),
        'syncOrder': i,
      },
  };
  final plans = <String, Object?>{};
  for (final item in converted['plans'] as List) {
    final plan = Map<String, Object?>.from(item as Map);
    plan.remove('currentPointId');
    plan.remove('currentGroupId');
    final completed = (plan['completedPointIds'] as List)
        .cast<String>()
        .toSet();
    plan['completedPointIds'] = {
      for (final point in plan['points'] as List)
        (point as Map)['id'] as String: completed.contains(point['id']),
    };
    for (final name in ['works', 'points', 'groups']) {
      plan[name] = keyed(plan[name] as List);
    }
    plan['visitRecords'] = {
      for (final record in converted['visitRecords'] as List)
        if ((record as Map)['planId'] == plan['id'])
          record['id'] as String: record,
    };
    plans[plan['id'] as String] = plan;
  }
  return CapturedSyncSnapshot({'plans': plans}, local, assets);
}

Set<String> syncImageHashes(Object? value) {
  final hashes = <String>{};
  void visit(Object? v) {
    if (v is Map) {
      for (final entry in v.entries) {
        if (syncImageFields.contains(entry.key) &&
            entry.value != null &&
            entry.value != '') {
          final match = entry.value is String
              ? syncHashPattern.firstMatch(entry.value as String)
              : null;
          if (match == null) throw const FormatException('云端包含无效的图片引用。');
          hashes.add(match.group(1)!);
        } else {
          visit(entry.value);
        }
      }
    } else if (v is List) {
      for (final e in v) {
        visit(e);
      }
    }
  }

  visit(value);
  return hashes;
}

SamplePilgrimageRepositorySnapshot restoreSyncSnapshot(
  SyncJson data,
  String localJson,
  Map<String, String> imagePaths,
) {
  final local = jsonDecode(localJson) as Map<String, dynamic>;
  final localPlans = {
    for (final p in local['plans'] as List) (p as Map)['id']: p,
  };
  final records = <Object?>[];
  List<SyncJson> values(Object? source) {
    if (source is! Map) throw const FormatException('云端数据结构无效。');
    final result = <SyncJson>[];
    for (final entry in source.entries) {
      if (entry.value == null) continue;
      if (entry.value is! Map || (entry.value as Map)['id'] != entry.key) {
        throw const FormatException('云端记录 ID 无效。');
      }
      result.add(Map<String, Object?>.from(entry.value as Map));
    }
    result.sort((a, b) {
      final order = ((a['syncOrder'] as num?) ?? 0).compareTo(
        (b['syncOrder'] as num?) ?? 0,
      );
      return order != 0
          ? order
          : (a['id'] as String).compareTo(b['id'] as String);
    });
    return result;
  }

  final plans = values(data['plans']);
  if (plans.isEmpty) throw const FormatException('至少需要保留一个计划，请创建计划后重试。');
  for (final plan in plans) {
    for (final key in ['works', 'points', 'groups']) {
      plan[key] = values(plan[key]);
    }
    final points = plan['points'] as List<SyncJson>;
    final works = (plan['works'] as List<SyncJson>).map((w) => w['id']).toSet();
    final groups = (plan['groups'] as List<SyncJson>)
        .map((g) => g['id'])
        .toSet();
    final pointIds = points.map((p) => p['id']).toSet();
    for (final point in points) {
      if (!works.contains(point['workId'])) {
        throw const FormatException('合并后有点位缺少作品，请先解决关联数据冲突。');
      }
      if (!groups.contains(point['groupId'])) {
        point['groupId'] = null;
        point['groupOrderIndex'] = null;
      }
    }
    final completed = plan['completedPointIds'];
    if (completed is! Map) throw const FormatException('完成状态无效。');
    plan['completedPointIds'] = [
      for (final e in completed.entries)
        if (e.value == true && pointIds.contains(e.key)) e.key,
    ];
    final previous = localPlans[plan['id']];
    plan['currentPointId'] =
        previous is Map && pointIds.contains(previous['currentPointId'])
        ? previous['currentPointId']
        : null;
    plan['currentGroupId'] =
        previous is Map && groups.contains(previous['currentGroupId'])
        ? previous['currentGroupId']
        : null;
    for (final record in values(plan.remove('visitRecords'))) {
      if (record['planId'] != plan['id']) {
        throw const FormatException('记录所属计划无效。');
      }
      records.add(record);
    }
  }
  if (records.map((r) => (r as Map)['id']).toSet().length != records.length) {
    throw const FormatException('存在重复的巡礼记录 ID。');
  }
  Object? resolve(Object? v) {
    if (v is Map) {
      return {
        for (final e in v.entries)
          e.key:
              syncImageFields.contains(e.key) &&
                  e.value is String &&
                  (e.value as String).isNotEmpty
              ? imagePaths[syncHashPattern
                        .firstMatch(e.value as String)
                        ?.group(1)] ??
                    (throw const FormatException('同步照片尚未下载完成。'))
              : resolve(e.value),
      };
    }
    if (v is List) return v.map(resolve).toList();
    return v;
  }

  final result = decodeDesktopRepositoryState(
    jsonEncode({
      'schemaVersion': 1,
      'plans': resolve(plans),
      'visitRecords': resolve(records),
      'settings': local['settings'],
      'activePlanId': local['activePlanId'],
    }),
  );
  if (result == null) throw const FormatException('无法读取同步数据。');
  return result;
}
