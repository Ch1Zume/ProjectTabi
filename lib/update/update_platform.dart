import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../desktop/tauri_bridge.dart';

bool get supportsAppUpdates => isTauriLauncherAvailable ||
    (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

Future<Map<String, Object?>> updateCommand(String action, {
  bool wifiOnly = false,
}) async {
  final request = <String, Object?>{'action': action, 'wifiOnly': wifiOnly};
  if (isTauriLauncherAvailable) {
    return invokeWebDavCommand('updater_command', request);
  }
  final result = await const MethodChannel('projecttabi/updater')
      .invokeMapMethod<String, Object?>('command', request);
  return result ?? <String, Object?>{};
}
