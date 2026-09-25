import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../sync/sync_platform.dart';
import 'camera_quality_sheet.dart';

/// Camera preferences and the last observed capabilities belong to this device.
class CameraPreferences extends ChangeNotifier {
  CameraPreferences._();
  static final instance = CameraPreferences._();
  String mode = 'auto';
  CameraQualityState? lastQuality;
  String? observedAt;
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    try {
      final data = jsonDecode(await syncStoreRead('camera_preferences') ?? '{}') as Map;
      final saved = data['mode'];
      if (const ['auto', 'hdr', 'night', 'off'].contains(saved)) mode = saved as String;
      lastQuality = CameraQualityState.fromPlatform(data['quality']);
      observedAt = data['observedAt'] as String?;
    } catch (_) { /* Missing preferences use the safe defaults. */ }
    notifyListeners();
  }

  Future<void> select(String value) async {
    await load();
    if (!const ['auto', 'hdr', 'night', 'off'].contains(value)) return;
    final previous = mode;
    mode = value;
    try { await _save(); } catch (_) { mode = previous; rethrow; }
    notifyListeners();
  }

  Future<void> remember(CameraQualityState? value) async {
    if (value == null) return;
    await load();
    lastQuality = value;
    observedAt = DateTime.now().toIso8601String();
    try { await _save(); } catch (_) { /* Diagnostics do not block capture. */ }
    notifyListeners();
  }

  Future<void> _save() {
    final encoded = jsonEncode({'mode': mode, 'observedAt': observedAt,
      if (lastQuality case final quality?) 'quality': {
        'requestedMode': quality.requestedMode, 'activeMode': quality.activeMode,
        'availableModes': quality.availableModes.toList(), 'lensLabel': quality.lensLabel,
        'notice': quality.notice, 'outputSize': quality.outputSize,
        'diagnostics': quality.diagnostics, 'telephotoAvailable': quality.telephotoAvailable,
      },
    });
    final write = _writes.then((_) => syncStoreWrite('camera_preferences', encoded));
    _writes = write.catchError((Object _) {});
    return write;
  }
}
