import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'desktop/tauri_bridge.dart';

const projectTabiAppVersion = '0.1.1+3';

Future<String> loadAppVersionLabel({
  bool? desktopLauncherAvailable,
  Future<PackageInfo> Function()? packageInfoLoader,
}) async {
  // The web plugin cannot resolve version.json under Tauri's custom scheme.
  if (desktopLauncherAvailable ?? isTauriLauncherAvailable) {
    return projectTabiAppVersion;
  }
  try {
    final info = await (packageInfoLoader ?? PackageInfo.fromPlatform)();
    if (info.version.trim().isEmpty) {
      return projectTabiAppVersion;
    }
    return formatAppVersionLabel(
      version: info.version,
      buildNumber: info.buildNumber,
    );
  } catch (error) {
    debugPrint('App version query failed: $error');
    return projectTabiAppVersion;
  }
}

String formatAppVersionLabel({
  required String version,
  required String buildNumber,
}) {
  final trimmedBuildNumber = buildNumber.trim();
  if (trimmedBuildNumber.isEmpty) {
    return version;
  }
  return '$version+$trimmedBuildNumber';
}
