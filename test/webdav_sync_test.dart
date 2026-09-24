import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:project_tabi/data/local/app_database.dart';
import 'package:project_tabi/data/local/sqlite_pilgrimage_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:project_tabi/data/sample_pilgrimage_repository.dart';
import 'package:project_tabi/plan/pilgrimage_models.dart';
import 'package:project_tabi/sync/sync_merge.dart';
import 'package:project_tabi/sync/sync_guard_repository.dart';
import 'package:project_tabi/sync/sync_service.dart';
import 'package:project_tabi/sync/sync_snapshot.dart';
import 'package:project_tabi/sync/webdav_client.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class _Dav {
  final files = <String, List<int>>{};
  int revision = 0, imageUploads = 0;
  bool rejectNextManifest = false;
  http.Response handle(http.Request request) {
    final path = request.url.path;
    if (request.method == 'PROPFIND') {
      return http.Response('<multistatus/>', 207);
    }
    if (request.method == 'MKCOL') return http.Response('', 201);
    if (request.method == 'HEAD') {
      return http.Response('', files.containsKey(path) ? 200 : 404);
    }
    if (request.method == 'GET') {
      return files.containsKey(path)
          ? http.Response.bytes(
              files[path]!,
              200,
              headers: {'etag': '"$revision"'},
            )
          : http.Response('', 404);
    }
    if (request.method == 'PUT') {
      if (path.endsWith('manifest-v1.json')) {
        if (rejectNextManifest) {
          rejectNextManifest = false;
          return http.Response('', 412);
        }
        if (files.containsKey(path) &&
            request.headers['if-match'] != '"$revision"') {
          return http.Response('', 412);
        }
        if (!files.containsKey(path) &&
            request.headers['if-none-match'] != '*') {
          return http.Response('', 412);
        }
        revision++;
      } else {
        if (files.containsKey(path)) return http.Response('', 412);
        if (path.contains('/objects/')) imageUploads++;
      }
      files[path] = List.of(request.bodyBytes);
      return http.Response('', 201);
    }
    throw StateError('Unexpected method');
  }
}

PilgrimagePlan _plan(String id) => PilgrimagePlan(
  id: id,
  name: id,
  area: 'Tokyo',
  works: const [],
  points: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('repository writes wait until an exclusive sync completes', () async {
    final underlying = SamplePilgrimageRepository(
      plans: [_plan('a')],
      visitRecords: [],
    );
    final guarded = SyncGuardRepository(underlying);
    final started = Completer<void>();
    final release = Completer<void>();
    final job = guarded.exclusive(() async {
      started.complete();
      await release.future;
      expect((await guarded.loadActivePlan()).memo, '');
    });
    await started.future;
    final write = guarded.updatePlanMemo(planId: 'a', memo: 'queued');
    expect((await underlying.loadActivePlan()).memo, '');
    release.complete();
    await job;
    await write;
    expect((await underlying.loadActivePlan()).memo, 'queued');
  });
  test('independent fields merge; deletion versus edit requires a choice', () {
    final base = <String, Object?>{
      'plans': {
        'p': {'id': 'p', 'memo': '', 'name': 'old'},
      },
    };
    final a = <String, Object?>{
      'plans': {
        'p': {'id': 'p', 'memo': 'phone', 'name': 'old'},
      },
    };
    final b = <String, Object?>{
      'plans': {
        'p': {'id': 'p', 'memo': '', 'name': 'desktop'},
      },
    };
    final merged = mergeSyncData(base, a, b);
    expect(merged.conflicts, isEmpty);
    expect((merged.data['plans'] as Map)['p'], {
      'id': 'p',
      'memo': 'phone',
      'name': 'desktop',
    });
    final deleted = addSyncTombstones({'plans': <String, Object?>{}}, base);
    expect(mergeSyncData(base, deleted, b).conflicts.single.path, 'plans/p');
    expect(
      (mergeSyncData(
            base,
            deleted,
            b,
            useRemote: {'plans/p': false},
          ).data['plans']
          as Map)['p'],
      isNull,
    );
  });
  test(
    'new device cannot silently resurrect tombstones; photos remain atomic',
    () {
      expect(
        mergeSyncData(
          {'plans': <String, Object?>{}},
          {
            'plans': {
              'p': {'id': 'p'},
            },
          },
          {
            'plans': {'p': null},
          },
        ).conflicts,
        hasLength(1),
      );
      final base = <String, Object?>{
        'visitRecords': {
          'r': {'id': 'r', 'photoPath': 'a', 'intensity': 0},
        },
      };
      final a = <String, Object?>{
        'visitRecords': {
          'r': {'id': 'r', 'photoPath': 'b', 'intensity': 0},
        },
      };
      final b = <String, Object?>{
        'visitRecords': {
          'r': {'id': 'r', 'photoPath': 'a', 'intensity': 1},
        },
      };
      expect(mergeSyncData(base, a, b).conflicts, hasLength(1));
      expect(syncImageHashes({'memo': 'sync:not-an-image'}), isEmpty);
      expect(
        () => syncImageHashes({'photoPath': '/private/local.jpg'}),
        throwsFormatException,
      );
    },
  );
  test('reject insecure, browser and credential-bearing URLs', () {
    for (final v in [
      'http://example.com/dav/',
      Uri(
        scheme: 'https',
        userInfo: 'test',
        host: 'example.com',
        path: '/dav/',
      ).toString(),
      'https://example.com/browser/',
      'https://example.com/dav/?ignored=1',
    ]) {
      expect(() => WebDavConfig.validateUrl(v), throwsFormatException);
    }
  });
  late Directory temp;
  late _Paths paths;
  late PathProviderPlatform previous;
  late _Dav server;
  late List<WebDavClient> clients;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('miriago-sync-');
    paths = _Paths('${temp.path}/a');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = paths;
    server = _Dav();
    clients = [];
  });
  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    PathProviderPlatform.instance = previous;
    await temp.delete(recursive: true);
  });
  Future<bool> sync(
    SamplePilgrimageRepository repo,
    String device, {
    Future<Map<String, bool>?> Function(List<SyncConflict>)? resolve,
  }) async {
    paths.root = '${temp.path}/$device';
    final client = WebDavClient(
      WebDavConfig(url: 'https://example.com/dav/', username: 'test'),
      'test-app-password',
      client: MockClient((r) async => server.handle(r)),
    );
    clients.add(client);
    return SyncService(repo, client).synchronize(
      resolve:
          resolve ??
          (c) async =>
              throw StateError('Unexpected conflicts: ${c.map((e) => e.path)}'),
      progress: (_) {},
    );
  }

  test(
    'SQLite sync replacement preserves IDs and rolls back invalid snapshots',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = SqlitePilgrimageRepository(database: db);
      final state = SamplePilgrimageRepositorySnapshot(
        plans: [_plan('synced')],
        visitRecords: const [],
        settings: const AppSettings(),
        activePlanId: 'synced',
      );
      await repo.replaceSyncSnapshot(state);
      expect((await repo.loadPlans()).single.id, 'synced');
      final invalid = SamplePilgrimageRepositorySnapshot(
        plans: [_plan('duplicate'), _plan('duplicate')],
        visitRecords: const [],
        settings: const AppSettings(),
        activePlanId: 'duplicate',
      );
      await expectLater(repo.replaceSyncSnapshot(invalid), throwsA(anything));
      expect((await repo.loadPlans()).single.id, 'synced');
    },
  );
  test(
    'two devices converge, retain IDs, and propagate deletions without duplicates',
    () async {
      final a = SamplePilgrimageRepository(
        plans: [_plan('a')],
        visitRecords: [],
      );
      final b = SamplePilgrimageRepository(
        plans: [_plan('b')],
        visitRecords: [],
      );
      await sync(a, 'a');
      await sync(b, 'b');
      await sync(a, 'a');
      expect((await a.loadPlans()).map((p) => p.id).toSet(), {'a', 'b'});
      await a.updatePlanMemo(planId: 'a', memo: 'phone');
      await b.renamePlan(planId: 'a', name: 'desktop');
      await sync(a, 'a');
      await sync(b, 'b');
      await sync(a, 'a');
      final plan = (await a.loadPlans()).firstWhere((p) => p.id == 'a');
      expect(plan.memo, 'phone');
      expect(plan.name, 'desktop');
      await a.deletePlan('b');
      await sync(a, 'a');
      await sync(b, 'b');
      await sync(b, 'b');
      expect((await b.loadPlans()).map((p) => p.id).toList(), ['a']);
    },
  );
  test(
    'photos transfer byte-for-byte, use local paths and upload once',
    () async {
      final image = File('${temp.path}/original.png');
      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=',
      );
      await image.writeAsBytes(bytes);
      final a = SamplePilgrimageRepository(
        plans: [_plan('a')],
        visitRecords: [],
      );
      final b = SamplePilgrimageRepository(
        plans: [_plan('b')],
        visitRecords: [],
      );
      final record = await a.createVisitRecord(
        planId: 'a',
        pointId: 'historic-point',
        workId: 'historic-work',
        photoPath: image.path,
        referenceMode: 'test',
      );
      await sync(a, 'a');
      await sync(b, 'b');
      final downloaded = (await b.loadVisitRecords('a')).single;
      expect(downloaded.id, record.id);
      expect(downloaded.photoPath, isNot(image.path));
      expect(await File(downloaded.photoPath).readAsBytes(), bytes);
      await sync(b, 'b');
      expect(server.imageUploads, 1);
      expect(
        utf8.decode(server.files['/dav/MiriaGoSync/manifest-v1.json']!),
        isNot(contains(temp.path)),
      );
      await a.deleteVisitRecord(planId: 'a', recordId: record.id);
      await sync(a, 'a');
      await sync(b, 'b');
      expect(await b.loadVisitRecords('a'), isEmpty);
    },
  );
  test('ETag rejection preserves local edits; retry succeeds', () async {
    final a = SamplePilgrimageRepository(plans: [_plan('a')], visitRecords: []);
    await sync(a, 'a');
    await a.updatePlanMemo(planId: 'a', memo: 'pending');
    final before = await captureLocalJson(a);
    server.rejectNextManifest = true;
    await expectLater(sync(a, 'a'), throwsA(isA<SyncChangedRemotely>()));
    expect(await captureLocalJson(a), before);
    await sync(a, 'a');
    expect((await a.loadActivePlan()).memo, 'pending');
  });
  test(
    'canceling conflict writes nothing; damaged manifest cannot erase records',
    () async {
      final a = SamplePilgrimageRepository(
        plans: [_plan('a')],
        visitRecords: [],
      );
      final b = SamplePilgrimageRepository(
        plans: [_plan('b')],
        visitRecords: [],
      );
      await sync(a, 'a');
      await sync(b, 'b');
      await sync(a, 'a');
      await a.updatePlanMemo(planId: 'a', memo: 'phone');
      await b.updatePlanMemo(planId: 'a', memo: 'desktop');
      await sync(a, 'a');
      final revision = server.revision;
      expect(await sync(b, 'b', resolve: (_) async => null), isFalse);
      expect(server.revision, revision);
      expect(
        (await b.loadPlans()).firstWhere((p) => p.id == 'a').memo,
        'desktop',
      );
      final before = await captureLocalJson(a);
      server.files.remove('/dav/MiriaGoSync/manifest-v1.json');
      await expectLater(sync(a, 'a'), throwsException);
      expect(await captureLocalJson(a), before);
      server.files['/dav/MiriaGoSync/manifest-v1.json'] = utf8.encode(
        '{"version":999}',
      );
      await expectLater(sync(a, 'a'), throwsFormatException);
      expect(await captureLocalJson(a), before);
    },
  );
}
