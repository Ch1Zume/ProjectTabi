import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:project_tabi/data/app_managed_file_paths_io.dart';
import 'package:project_tabi/data/reference_image_cache_io.dart';
import 'package:project_tabi/data/sample_pilgrimage_repository.dart';
import 'package:project_tabi/plan/pilgrimage_models.dart';
import 'package:project_tabi/plan_transfer/plan_export_asset_io.dart';
import 'package:project_tabi/sync/sync_failure.dart';
import 'package:project_tabi/sync/sync_guard_repository.dart';
import 'package:project_tabi/sync/sync_image_format.dart';
import 'package:project_tabi/sync/sync_platform.dart';
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
  final methods = <String>[];
  int revision = 0, imageUploads = 0, imageDownloads = 0;
  bool rejectManifest = false, corruptImage = false;
  http.Response handle(http.Request r) {
    final path = r.url.path.split('/MiriaGoSync/').last;
    methods.add('${r.method} $path');
    if (r.method == 'PROPFIND') return http.Response('', 207);
    if (r.method == 'MKCOL') return http.Response('', 201);
    if (r.method == 'HEAD') {
      return http.Response('', files.containsKey(path) ? 200 : 404);
    }
    if (r.method == 'GET') {
      if (!files.containsKey(path)) return http.Response('', 404);
      if (path.startsWith('objects/')) imageDownloads++;
      return http.Response.bytes(
        corruptImage && path.startsWith('objects/') ? [0] : files[path]!,
        200,
        headers: {'etag': '"$revision"'},
      );
    }
    if (r.method == 'PUT') {
      if (path == 'manifest-v1.json') {
        if (rejectManifest ||
            (files.containsKey(path) && r.headers['if-match'] != '"$revision"')) {
          return http.Response('', 412);
        }
        revision++;
      } else {
        if (files.containsKey(path)) return http.Response('', 412);
        if (path.startsWith('objects/')) imageUploads++;
      }
      files[path] = List.of(r.bodyBytes);
      return http.Response('', 201);
    }
    throw StateError('Unexpected request');
  }
}

const _work = PilgrimageWork(
  id: 'w',
  title: '作品',
  subtitle: '',
  city: '',
  source: WorkSource.manual,
);
PilgrimagePoint _point({String? thumbnail, String? full, String? url}) =>
    PilgrimagePoint(
      id: 'point',
      work: _work,
      name: '参考点位',
      subtitle: '',
      position: const LatLng(35, 139),
      episodeLabel: '',
      referenceLabel: '',
      referenceImageUrl: url,
      referenceThumbnailPath: thumbnail,
      referenceFullImagePath: full,
    );
PilgrimagePlan _plan(String id, {List<PilgrimagePoint> points = const []}) =>
    PilgrimagePlan(
      id: id,
      name: '旅行计划$id',
      area: '',
      works: const [_work],
      points: points,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _Paths paths;
  late PathProviderPlatform old;
  late _Dav dav;
  final gif = base64Decode(
    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sync-assets-');
    old = PathProviderPlatform.instance;
    paths = _Paths('${temp.path}/phone');
    PathProviderPlatform.instance = paths;
    setAppManagedFileBaseDirectoriesForTesting([paths.root]);
    dav = _Dav();
  });
  tearDown(() async {
    PathProviderPlatform.instance = old;
    setAppManagedFileBaseDirectoriesForTesting(null);
    await temp.delete(recursive: true);
  });
  Future<File> image(String name) async =>
      File('${temp.path}/$name').writeAsBytes(gif);
  WebDavClient client() {
    final c = WebDavClient(
      WebDavConfig(url: 'https://sync.example/dav/', username: 'tester'),
      'fixture',
      client: MockClient((r) async => dav.handle(r)),
    );
    addTearDown(c.close);
    return c;
  }

  Future<bool> sync(
    SamplePilgrimageRepository repo,
    SyncDirection direction, {
    String device = 'phone',
  }) async {
    paths.root = '${temp.path}/$device';
    return SyncService(repo, client()).synchronize(
      direction: direction,
      resolve: (_) async => {},
      progress: (_) {},
    );
  }

  test(
    'sync preserves GIF and HEIF bytes without loosening export validation',
    () async {
      final f = await image('original.gif');
      expect(await readExportAssetBytes(f.path), isNull);
      expect(await readSyncImage(f.path), gif);
      expect(syncImageExtension(gif), 'gif');
      final heic = [
        0,
        0,
        0,
        20,
        ...'ftypheic'.codeUnits,
        0,
        0,
        0,
        0,
        ...'mif1'.codeUnits,
      ];
      await f.writeAsBytes(heic);
      expect(await readSyncImage(f.path), heic);
      expect(syncImageExtension(heic), 'heic');
      expect(syncImageExtension([1, 2]), 'bin');
    },
  );
  test('file URIs and moved sync image paths resolve', () async {
    final f = await image('photo with space.gif');
    expect(await readSyncImage(f.uri.toString()), gif);
    final dir = await Directory(
      '${paths.root}/webdav_sync_assets',
    ).create(recursive: true);
    await File('${dir.path}/photo.gif').writeAsBytes(gif);
    expect(
      await readSyncImage('/old/app_flutter/webdav_sync_assets/photo.gif'),
      gif,
    );
  });
  test(
    'missing custom thumbnail uses full image; missing original identifies record',
    () async {
      final f = await image('full.gif');
      final repo = SamplePilgrimageRepository(
        plans: [
          _plan(
            'a',
            points: [_point(thumbnail: '${temp.path}/gone.gif', full: f.path)],
          ),
        ],
        visitRecords: [],
      );
      final captured = await captureSyncSnapshot(repo);
      final p = ((captured.data['plans'] as Map)['a'] as Map)['points'] as Map;
      expect(
        (p['point'] as Map)['referenceThumbnailPath'],
        (p['point'] as Map)['referenceFullImagePath'],
      );
      final record = await repo.createVisitRecord(
        planId: 'a',
        pointId: 'point',
        workId: 'w',
        pointName: '照片点位',
        photoPath: f.path,
        referenceMode: 'none',
      );
      await repo.updateVisitRecordColorGrading(
        planId: 'a',
        recordId: record.id,
        originalPhotoPath: '${temp.path}/missing-original.gif',
        gradedPhotoPath: f.path,
        colorGradingMode: 'test',
        colorGradingParamsJson: '{}',
        colorGradingIntensity: 1,
      );
      await expectLater(
        captureSyncSnapshot(repo),
        throwsA(
          isA<SyncAssetReadException>()
              .having((e) => e.field, 'field', 'originalPhotoPath')
              .having((e) => e.toString(), 'record', contains('照片点位')),
        ),
      );
      final before = await captureLocalJson(repo);
      await expectLater(
        sync(repo, SyncDirection.upload),
        throwsA(isA<SyncAssetReadException>()),
      );
      expect(dav.methods.where((r) => r.startsWith('PUT')), isEmpty);
      expect(await captureLocalJson(repo), before);
    },
  );
  test(
    'synced thumbnail is reused without refetch or cache path rewrite',
    () async {
      final hash = sha256.convert(gif).toString();
      final path = await syncWriteImage(hash, gif);
      expect(
        await ensureReferenceThumbnailCached(
          _point(
            thumbnail: path,
            url: 'https://api.anitabi.cn/images/test.jpg',
          ),
        ),
        path,
      );
    },
  );
  test(
    'direction choice cancels before mutation and presents counts and times',
    () async {
      final repo = SamplePilgrimageRepository(
        plans: [_plan('a')],
        visitRecords: [],
      );
      final changed = DateTime.utc(2026, 9, 24, 12);
      await syncStoreWrite('local_changed_at', changed.toIso8601String());
      final ok = await SyncService(repo, client()).synchronize(
        resolve: (_) async => {},
        progress: (_) {},
        chooseDirection: (p) async {
          expect(p.localUpdatedAt, changed);
          expect(p.localPlans, 1);
          expect(p.hasRemote, isFalse);
          return null;
        },
      );
      expect(ok, isFalse);
      expect(
        dav.methods.where((r) => r.startsWith('PUT') || r.startsWith('MKCOL')),
        isEmpty,
      );
    },
  );
  test(
    'explicit upload and download preserve chosen version; repeat transfers nothing',
    () async {
      final f = await image('photo.gif');
      final a = SamplePilgrimageRepository(
        plans: [_plan('a')],
        visitRecords: [],
      );
      final b = SamplePilgrimageRepository(
        plans: [_plan('b')],
        visitRecords: [],
      );
      await a.createVisitRecord(
        planId: 'a',
        pointId: 'p',
        workId: 'w',
        photoPath: f.path,
        referenceMode: 'none',
      );
      await sync(a, SyncDirection.upload);
      final stamp =
          (jsonDecode(utf8.decode(dav.files['manifest-v1.json']!))
              as Map)['updatedAt'];
      await sync(b, SyncDirection.download, device: 'desktop');
      expect((await b.loadPlans()).map((p) => p.id).toList(), ['a']);
      final downloaded = (await b.loadVisitRecords('a')).single;
      expect(await File(downloaded.photoPath).readAsBytes(), gif);
      expect(downloaded.photoPath, endsWith('.gif'));
      final revision = dav.revision;
      await sync(b, SyncDirection.merge, device: 'desktop');
      expect(dav.revision, revision);
      expect(dav.imageUploads, 1);
      expect(dav.imageDownloads, 1);
      expect(
        (jsonDecode(utf8.decode(dav.files['manifest-v1.json']!))
            as Map)['updatedAt'],
        stamp,
      );
      await b.renamePlan(planId: 'a', name: '桌面保留');
      await sync(b, SyncDirection.upload, device: 'desktop');
      expect(dav.files.keys.where((p) => p.startsWith('history/')), isNotEmpty);
      await sync(a, SyncDirection.download);
      expect((await a.loadActivePlan()).name, '桌面保留');
    },
  );
  test('pull repairs a missing local photo without uploading it', () async {
    final f = await image('repair.gif');
    final a = SamplePilgrimageRepository(plans: [_plan('a')], visitRecords: []);
    await a.createVisitRecord(
      planId: 'a',
      pointId: 'p',
      workId: 'w',
      photoPath: f.path,
      referenceMode: 'none',
    );
    await sync(a, SyncDirection.upload);
    await f.delete();
    final puts = dav.methods.where((r) => r.startsWith('PUT')).length;
    await sync(a, SyncDirection.download);
    expect(
      await File(
        (await a.loadVisitRecords('a')).single.photoPath,
      ).readAsBytes(),
      gif,
    );
    expect(dav.methods.where((r) => r.startsWith('PUT')).length, puts);
  });
  test(
    'damaged cloud image and concurrent cloud change preserve local data',
    () async {
      final f = await image('photo.gif');
      final a = SamplePilgrimageRepository(
        plans: [_plan('a')],
        visitRecords: [],
      );
      final b = SamplePilgrimageRepository(
        plans: [_plan('b')],
        visitRecords: [],
      );
      await a.createVisitRecord(
        planId: 'a',
        pointId: 'p',
        workId: 'w',
        photoPath: f.path,
        referenceMode: 'none',
      );
      await sync(a, SyncDirection.upload);
      final before = await captureLocalJson(b);
      dav.corruptImage = true;
      await expectLater(
        sync(b, SyncDirection.download, device: 'desktop'),
        throwsFormatException,
      );
      expect(await captureLocalJson(b), before);
      dav.corruptImage = false;
      dav.rejectManifest = true;
      await expectLater(
        sync(b, SyncDirection.upload, device: 'desktop'),
        throwsA(isA<SyncChangedRemotely>()),
      );
      expect(await captureLocalJson(b), before);
    },
  );
  test('metadata failure after applying a pull reports committed local data', () async {
    final a = SamplePilgrimageRepository(plans: [_plan('a')], visitRecords: []);
    final b = SamplePilgrimageRepository(plans: [_plan('b')], visitRecords: []);
    await sync(a, SyncDirection.upload);
    paths.root = '${temp.path}/desktop';
    final c = client();
    final key = syncAccountKey(c.config);
    await Directory('${paths.root}/webdav_sync/baseline_$key').create(recursive: true);
    final service = SyncService(b, c);
    await expectLater(service.synchronize(direction: SyncDirection.download,
        resolve: (_) async => {}, progress: (_) {}), throwsA(isA<FileSystemException>()));
    expect((await b.loadPlans()).single.id, 'a');
    expect(service.lastFailure!.localDataChanged, isTrue);
    expect(service.lastFailure!.state, contains('记录已保存'));
    expect(await syncStoreRead('backup_$key'), contains('旅行计划b'));
  });
  test('HTTP diagnostics specify recovery and never display credentials', () {
    final c = client();
    for (final status in [401, 403, 404, 423, 429, 507, 500]) {
      try {
        c.check(DavResponse(status, const [], null), {200});
        fail('Expected error');
      } catch (e) {
        expect(e, isA<WebDavFailure>());
        final failure = SyncFailure.describe(e);
        expect(failure.message, contains('HTTP $status'));
        expect(failure.message, isNot(contains('fixture')));
        expect(failure.action, isNotEmpty);
      }
    }
  });
  test(
    'repository edit timestamps include record edits but exclude cache writes',
    () async {
      final repo = SyncGuardRepository(
        SamplePilgrimageRepository(
          plans: [
            _plan('a', points: [_point()]),
          ],
          visitRecords: [],
        ),
      );
      await repo.updatePlanMemo(planId: 'a', memo: 'changed');
      final timestamp = await syncStoreRead('local_changed_at');
      expect(DateTime.tryParse(timestamp!), isNotNull);
      await repo.updatePointImageCache(
        planId: 'a',
        pointId: 'point',
        referenceThumbnailPath: 'cache',
      );
      expect(await syncStoreRead('local_changed_at'), timestamp);
    },
  );
}
