import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../app_version.dart';
import '../sync/sync_platform.dart';
import 'update_activity.dart';
import 'update_platform.dart';

class AppUpdateController extends ChangeNotifier {
  AppUpdateController._();
  static final instance = AppUpdateController._();
  Map<String, Object?> state = {};
  bool autoCheck = true;
  bool wifiAutoDownload = false;
  String currentVersion = projectTabiAppVersion;
  String? error;
  int lastCheck = 0;
  String? _knownUpdate;
  int _revision = 0;
  Future<void> _preferenceTail = Future.value();
  Future<void>? _initializing;
  Timer? _timer;
  bool _commandBusy = false;
  bool _polling = false;
  bool _foreground = true;

  String get phase => state['phase'] as String? ?? 'idle';
  String? get version => state['version'] as String?;
  String get notes => state['notes'] as String? ?? '';
  int get downloaded => (state['downloaded'] as num?)?.toInt() ?? 0;
  int get total => (state['total'] as num?)?.toInt() ?? 0;
  bool get busy => _commandBusy || {'checking', 'downloading', 'verifying', 'installing'}.contains(phase);
  bool get hasUpdate => version != null && !{'idle', 'current'}.contains(phase);
  bool get supported => supportsAppUpdates && state['supported'] != false;

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    if (!supportsAppUpdates) return;
    currentVersion = await loadAppVersionLabel();
    try {
      final value = jsonDecode(await syncStoreRead('app_update_preferences') ?? '{}') as Map;
      autoCheck = value['autoCheck'] != false;
      wifiAutoDownload = value['wifiAutoDownload'] == true;
      lastCheck = (value['lastCheck'] as num?)?.toInt() ?? 0;
      _knownUpdate = value['knownUpdate'] as String?;
    } catch (_) {
      // A corrupt preference file does not prevent manual updates.
    }
    await _poll();
    _timer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (_foreground && {'downloading', 'waiting', 'verifying', 'installing'}.contains(phase)) {
        unawaited(_poll());
      }
    });
  }

  Future<void> onForeground(bool active) async {
    _foreground = active;
    if (!active) return;
    await initialize();
    if (!supported) return;
    await _poll();
    if (autoCheck && !busy && !hasUpdate &&
        ((_knownUpdate != null && phase == 'idle') ||
         DateTime.now().millisecondsSinceEpoch - lastCheck > const Duration(days: 1).inMilliseconds)) {
      await check(automatic: true);
    }
  }

  Future<void> savePreferences({bool? check, bool? download}) async {
    autoCheck = check ?? autoCheck;
    wifiAutoDownload = download ?? wifiAutoDownload;
    try {
      await _persistPreferences();
    } catch (_) {
      error = '设置未能保存，请检查可用存储空间后重试。';
    }
    notifyListeners();
    if (wifiAutoDownload && phase == 'available') await startDownload(wifiOnly: true);
  }

  Future<void> _persistPreferences() {
    final encoded = jsonEncode({
      'autoCheck': autoCheck, 'wifiAutoDownload': wifiAutoDownload,
      'lastCheck': lastCheck, 'knownUpdate': _knownUpdate,
    });
    final write = _preferenceTail.then((_) => syncStoreWrite('app_update_preferences', encoded));
    _preferenceTail = write.catchError((Object _) {});
    return write;
  }

  Future<void> check({bool automatic = false}) async {
    await initialize();
    if (busy || !supported || {'waiting', 'ready'}.contains(phase)) return;
    await _run('check');
    if (phase == 'current') _knownUpdate = null;
    if (hasUpdate) _knownUpdate = version;
    // Also throttle unreachable servers; a manual check is always available.
    lastCheck = DateTime.now().millisecondsSinceEpoch;
    try { await _persistPreferences(); } catch (_) { /* Keep update result. */ }
    if (wifiAutoDownload && phase == 'available') await startDownload(wifiOnly: true);
  }

  Future<void> startDownload({bool wifiOnly = false}) => _run('download', wifiOnly: wifiOnly);
  Future<void> cancelDownload() => _run('cancel', allowBusy: true);

  Future<void> install() async {
    if (UpdateActivity.busy) {
      error = '正在保存记录或同步，请完成后再安装更新。';
      notifyListeners();
      return;
    }
    UpdateActivity.installing = true;
    try { await _run('install'); } finally { UpdateActivity.installing = false; }
  }

  Future<void> _run(String action, {bool wifiOnly = false, bool allowBusy = false}) async {
    if (_commandBusy || (!allowBusy && busy)) return;
    _commandBusy = true;
    _revision++;
    error = null;
    if (action == 'check') state = {...state, 'phase': 'checking'};
    notifyListeners();
    try {
      state = await updateCommand(action, wifiOnly: wifiOnly);
      error = state['error'] as String?;
    } catch (e) {
      if (action == 'check') state = {...state, 'phase': 'error'};
      error = e is PlatformException
          ? e.message ?? '更新操作失败，请稍后重试。'
          : '更新操作失败，请检查网络连接后重试，或使用手动下载。';
    } finally {
      _commandBusy = false;
      notifyListeners();
    }
  }

  Future<void> _poll() async {
    if (_polling || _commandBusy || !supportsAppUpdates) return;
    _polling = true;
    final revision = _revision;
    try {
      final next = await updateCommand('status');
      if (revision != _revision) return;
      state = next;
      error = state['error'] as String?;
      notifyListeners();
    } catch (_) { /* A transient poll failure must not interrupt an active download. */ }
    finally { _polling = false; }
  }
}
