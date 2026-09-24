import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../data/pilgrimage_repository.dart';
import '../desktop/desktop_repository_state.dart';
import 'sync_failure.dart';
import 'sync_merge.dart';
import 'sync_platform.dart';
import 'sync_repository.dart';
import 'sync_guard_repository.dart';
import 'sync_snapshot.dart';
import 'webdav_client.dart';

typedef ResolveSyncConflicts =
    Future<Map<String, bool>?> Function(List<SyncConflict>);

enum SyncDirection { merge, upload, download }

typedef ChooseSyncDirection = Future<SyncDirection?> Function(SyncPreview);
String syncAccountKey(WebDavConfig config) =>
    sha256.convert(utf8.encode(config.identity)).toString();

class SyncHistoryEntry {
  const SyncHistoryEntry({
    required this.startedAt,
    required this.completedAt,
    required this.direction,
    required this.status,
    required this.summary,
  });

  final DateTime startedAt;
  final DateTime completedAt;
  final SyncDirection? direction;
  final String status;
  final String summary;

  String get directionLabel => switch (direction) {
    SyncDirection.upload => '本地 → 云端',
    SyncDirection.download => '云端 → 本地',
    SyncDirection.merge => '合并两端',
    null => '未选择方向',
  };

  String get statusLabel => switch (status) {
    'success' => '完成',
    'failed' => '失败',
    _ => '取消',
  };

  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toUtc().toIso8601String(),
    'completedAt': completedAt.toUtc().toIso8601String(),
    'direction': direction?.name,
    'status': status,
    'summary': summary,
  };

  static SyncHistoryEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final startedValue = value['startedAt'];
    final completedValue = value['completedAt'];
    final startedAt = DateTime.tryParse(
      startedValue is String ? startedValue : '',
    );
    final completedAt = DateTime.tryParse(
      completedValue is String ? completedValue : '',
    );
    if (startedAt == null || completedAt == null) return null;
    final directionName = value['direction'] is String
        ? value['direction'] as String
        : null;
    SyncDirection? direction;
    for (final candidate in SyncDirection.values) {
      if (candidate.name == directionName) {
        direction = candidate;
        break;
      }
    }
    return SyncHistoryEntry(
      startedAt: startedAt,
      completedAt: completedAt,
      direction: direction,
      status: value['status'] is String &&
              {'success', 'failed', 'cancelled'}.contains(value['status'])
          ? value['status'] as String
          : 'cancelled',
      summary: value['summary'] is String ? value['summary'] as String : '',
    );
  }
}

Future<List<SyncHistoryEntry>> readSyncHistory(String accountKey) async {
  try {
    final stored = await syncStoreRead('sync_history_$accountKey');
    if (stored == null) return const [];
    final decoded = jsonDecode(stored);
    if (decoded is! List) return const [];
    return decoded
        .map(SyncHistoryEntry.fromJson)
        .whereType<SyncHistoryEntry>()
        .take(30)
        .toList();
  } catch (_) {
    return const [];
  }
}

class SyncPreview {
  const SyncPreview({
    required this.localUpdatedAt,
    required this.remoteUpdatedAt,
    required this.localPlans,
    required this.localRecords,
    required this.remotePlans,
    required this.remoteRecords,
    required this.hasRemote,
    this.localTimeEstimated = false,
  });
  final DateTime? localUpdatedAt, remoteUpdatedAt;
  final int localPlans, localRecords, remotePlans, remoteRecords;
  final bool hasRemote, localTimeEstimated;
}

DateTime? _latestTimestamp(Object? value) {
  DateTime? latest;
  void visit(Object? v) {
    if (v is Map) {
      for (final e in v.entries) {
        if ({'updatedAt', 'capturedAt', 'createdAt'}.contains(e.key) &&
            e.value is String) {
          final time = DateTime.tryParse(e.value as String);
          if (time != null && (latest == null || time.isAfter(latest!))) {
            latest = time;
          }
        } else {
          visit(e.value);
        }
      }
    } else if (v is List) {
      for (final item in v) {
        visit(item);
      }
    }
  }

  visit(value);
  return latest;
}

class SyncService {
  SyncService(this.repository, this.client);
  final PilgrimageRepository repository;
  final WebDavClient client;
  static bool _running = false;
  SyncFailure? lastFailure;

  Future<List<SyncHistoryEntry>> loadHistory() =>
      readSyncHistory(syncAccountKey(client.config));

  Future<void> _appendHistory({
    required DateTime startedAt,
    required DateTime completedAt,
    required SyncDirection? direction,
    required String status,
    required String summary,
  }) async {
    try {
      final account = syncAccountKey(client.config);
      final previous = await readSyncHistory(account);
      final entries = [
        SyncHistoryEntry(
          startedAt: startedAt,
          completedAt: completedAt,
          direction: direction,
          status: status,
          summary: summary,
        ),
        ...previous,
      ].take(30);
      await syncStoreWrite(
        'sync_history_$account',
        jsonEncode(entries.map((entry) => entry.toJson()).toList()),
      );
    } catch (_) {
      // A history write must never change the outcome of the data sync.
    }
  }

  Future<SyncPreview> _preview(String localJson, SyncJson? remote) async {
    final local = jsonDecode(localJson) as Map;
    final stored = await syncStoreRead('local_changed_at');
    final plans =
        ((remote?['data'] as Map?)?['plans'] as Map?)?.values
            .whereType<Map>()
            .toList() ??
        [];
    return SyncPreview(
      localUpdatedAt:
          DateTime.tryParse(stored ?? '') ?? _latestTimestamp(local),
      localTimeEstimated: DateTime.tryParse(stored ?? '') == null,
      remoteUpdatedAt: DateTime.tryParse(remote?['updatedAt'] as String? ?? ''),
      localPlans: (local['plans'] as List).length,
      localRecords: (local['visitRecords'] as List).length,
      remotePlans: plans.length,
      remoteRecords: plans.fold<int>(
        0,
        (n, p) =>
            n +
            ((p['visitRecords'] as Map?)?.values.whereType<Map>().length ?? 0),
      ),
      hasRemote: remote != null,
    );
  }

  Future<SyncPreview> inspect() async {
    final guarded = repository;
    if (guarded is SyncGuardRepository && !guarded.inExclusiveSync) {
      return guarded.exclusive(inspect);
    }
    await client.testConnection();
    final response = await client.request('GET', 'manifest-v1.json');
    client.check(response, {200, 404});
    return _preview(
      await captureLocalJson(repository),
      response.status == 200 ? _manifest(response.bytes) : null,
    );
  }

  Future<bool> synchronize({
    required ResolveSyncConflicts resolve,
    required void Function(String) progress,
    SyncDirection direction = SyncDirection.merge,
    ChooseSyncDirection? chooseDirection,
  }) async {
    final guarded = repository;
    if (guarded is SyncGuardRepository && !guarded.inExclusiveSync) {
      return guarded.exclusive(
        () => synchronize(
          resolve: resolve,
          progress: progress,
          direction: direction,
          chooseDirection: chooseDirection,
        ),
      );
    }
    if (_running) throw StateError('同步正在进行，请稍候。');
    if (repository is! SyncRepository) throw UnsupportedError('此数据源不支持同步。');
    _running = true;
    lastFailure = null;
    final startedAt = DateTime.now().toUtc();
    SyncDirection? historyDirection =
        chooseDirection == null ? direction : null;
    var historyStatus = 'cancelled';
    var historySummary = '';
    var stage = '读取版本';
    var cloudWriteStarted = false,
        cloudCommitted = false,
        localCommitted = false;
    void report(String value) {
      stage = value;
      progress(value);
    }

    try {
      final account = syncAccountKey(client.config);
      report('读取两端版本…');
      await client.testConnection();
      final localJson = await captureLocalJson(repository);
      final response = await client.request('GET', 'manifest-v1.json');
      client.check(response, {200, 404});
      final remote = response.status == 200 ? _manifest(response.bytes) : null;
      if (chooseDirection != null) {
        final choice = await chooseDirection(await _preview(localJson, remote));
        if (choice == null) return false;
        direction = choice;
        historyDirection = direction;
      }
      if (direction == SyncDirection.download && remote == null) {
        throw const FormatException('云端还没有同步记录，无法下载。');
      }
      final stored = await syncStoreRead('baseline_$account');
      final baseline = stored == null ? null : _manifest(utf8.encode(stored));
      if (baseline != null &&
          remote == null &&
          direction == SyncDirection.merge) {
        throw const FormatException('已同步的云端清单不见了。请恢复清单，或明确选择“本地覆盖云端”。');
      }
      if (baseline != null &&
          remote != null &&
          remote['datasetId'] != baseline['datasetId'] &&
          direction == SyncDirection.merge) {
        throw const FormatException('云端数据集已更换，请明确选择要保留的版本。');
      }
      final baseData =
          baseline?['data'] as Map<String, Object?>? ??
          {'plans': <String, Object?>{}};
      final remoteData =
          remote?['data'] as Map<String, Object?>? ??
          {'plans': <String, Object?>{}};
      report('检查本地图片…');
      // A pull can repair missing local files; it must not require reading them first.
      final captured = direction == SyncDirection.download
          ? await captureSyncSnapshot(repository, tolerateMissingAssets: true)
          : await captureSyncSnapshot(repository);
      await _checkLocalUnchanged(localJson);
      final local = addSyncTombstones(captured.data, baseData);
      SyncJson selected;
      if (direction == SyncDirection.upload) {
        selected = addSyncTombstones(captured.data, remoteData);
      } else if (direction == SyncDirection.download) {
        selected = remoteData;
      } else {
        var merged = mergeSyncData(baseData, local, remoteData);
        if (merged.conflicts.isNotEmpty) {
          report('等待处理 ${merged.conflicts.length} 项冲突…');
          final choices = await resolve(merged.conflicts);
          if (choices == null) return false;
          merged = mergeSyncData(
            baseData,
            local,
            remoteData,
            useRemote: choices,
          );
          if (merged.conflicts.isNotEmpty) throw StateError('请处理全部冲突后再同步。');
        }
        selected = merged.data;
      }
      final hashes = syncImageHashes(selected);
      // Validate structure before uploading assets or committing either side.
      restoreSyncSnapshot(selected, localJson, {
        for (final hash in hashes) hash: 'pending/$hash',
      });
      final paths = <String, String>{};
      var uploads = 0, downloads = 0, checked = 0;
      if (direction != SyncDirection.download) await client.prepare();
      for (final hash in hashes) {
        report(
          '检查图片 ${++checked}/${hashes.length}（已上传 $uploads，下载 $downloads）',
        );
        final localPath = captured.assets[hash];
        if (localPath != null) {
          final bytes = await readSyncImage(localPath);
          if (sha256.convert(bytes).toString() != hash) {
            throw StateError('照片在同步中发生变化，请重试。');
          }
          if (direction != SyncDirection.download &&
              await client.putObject(hash, bytes)) {
            uploads++;
          }
          paths[hash] = localPath;
        } else {
          final image = await client.request('GET', 'objects/$hash');
          client.check(image, {200});
          if (sha256.convert(image.bytes).toString() != hash) {
            throw FormatException('云端图片校验失败：$hash。请恢复云端对应文件，或在源设备配置新的同步文件夹重新上传。');
          }
          paths[hash] = await syncWriteImage(hash, image.bytes);
          downloads++;
        }
      }
      final snapshot = restoreSyncSnapshot(selected, localJson, paths);
      final sameRemote =
          remote != null &&
          canonicalJson(selected) == canonicalJson(remoteData);
      final now = DateTime.now().toUtc().toIso8601String();
      final random = Random.secure();
      final document = sameRemote || direction == SyncDirection.download
          ? remote!
          : <String, Object?>{
              'format': 'miriago-webdav',
              'version': 1,
              'datasetId':
                  remote?['datasetId'] ??
                  List.generate(
                    16,
                    (_) =>
                        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
                  ).join(),
              'updatedAt': now,
              'data': selected,
            };
      final localWillChange =
          canonicalJson(jsonDecode(encodeDesktopRepositoryState(snapshot))) !=
          canonicalJson(jsonDecode(localJson));
      report('保存同步前备份…');
      await _checkLocalUnchanged(localJson);
      if (localWillChange) await syncStoreWrite('backup_$account', localJson);
      // Persist the cloud snapshot locally as well; no password is included.
      if (remote != null) {
        await syncStoreWrite('cloud_backup_$account', canonicalJson(remote));
      }
      if (direction != SyncDirection.download && !sameRemote) {
        if (remote != null) await client.backupManifest(response.bytes);
        report('提交云端版本…');
        cloudWriteStarted = true;
        await client.putManifest(
          utf8.encode(canonicalJson(document)),
          response.etag,
          exists: remote != null,
        );
        cloudCommitted = true;
      } else {
        // Especially for a pull: never apply a version superseded while downloading.
        report('复核云端版本…');
        final latest = await client.request('GET', 'manifest-v1.json');
        client.check(latest, {200});
        if (canonicalJson(_manifest(latest.bytes)) != canonicalJson(remote) ||
            latest.etag != response.etag) {
          throw SyncChangedRemotely();
        }
      }
      report('保存本地记录…');
      await _checkLocalUnchanged(localJson);
      if (localWillChange) {
        await (repository as SyncRepository).replaceSyncSnapshot(snapshot);
        localCommitted = true;
      }
      await syncStoreWrite('baseline_$account', canonicalJson(document));
      await syncStoreWrite('last_sync_$account', now);
      if (localWillChange) {
        await syncStoreWrite(
          'local_changed_at',
          document['updatedAt'] as String? ?? now,
        );
      }
      historyStatus = 'success';
      historySummary = '上传 $uploads 张，下载 $downloads 张';
      progress('同步完成：上传 $uploads 张，下载 $downloads 张。');
      return true;
    } catch (error) {
      lastFailure = SyncFailure.describe(
        error,
        stage: stage,
        cloudWriteStarted: cloudWriteStarted,
        cloudCommitted: cloudCommitted,
        localCommitted: localCommitted,
      );
      historyStatus = 'failed';
      historySummary = lastFailure!.code;
      rethrow;
    } finally {
      await _appendHistory(
        startedAt: startedAt,
        completedAt: DateTime.now().toUtc(),
        direction: historyDirection,
        status: historyStatus,
        summary: historySummary,
      );
      _running = false;
    }
  }

  Future<void> _checkLocalUnchanged(String expected) async {
    if (canonicalJson(jsonDecode(await captureLocalJson(repository))) !=
        canonicalJson(jsonDecode(expected))) {
      throw StateError('本地记录在同步时发生变化，已保留本地修改，请重新同步。');
    }
  }

  SyncJson _manifest(List<int> bytes) {
    if (bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('同步清单超过 32 MiB。');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic> ||
        value['format'] != 'miriago-webdav' ||
        value['version'] != 1 ||
        value['datasetId'] is! String ||
        value['data'] is! Map ||
        (value['data'] as Map)['plans'] is! Map ||
        (value['updatedAt'] != null &&
            (value['updatedAt'] is! String ||
                DateTime.tryParse(value['updatedAt'] as String) == null))) {
      throw const FormatException('云端清单无效或版本不兼容。');
    }
    return value;
  }
}
