import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String normalizeWorkflow(String source) => source.replaceAll('\r\n', '\n');

void main() {
  test('workflow assertions accept Windows checkout line endings', () {
    final source = File('.github/workflows/release.yml').readAsStringSync();
    final lf = normalizeWorkflow(source);
    expect(normalizeWorkflow(lf.replaceAll('\n', '\r\n')), lf);
  });
  test('desktop startup resources are bundled locally', () {
    final index = File('web/index.html').readAsStringSync();
    expect(index, contains('vendor/maplibre-gl/maplibre-gl.js'));
    expect(index, contains('vendor/maplibre-gl/maplibre-gl.css'));
    expect(index, isNot(contains('src="https://')));
    expect(index, isNot(contains('href="https://')));
    expect(
      File('web/vendor/maplibre-gl/maplibre-gl.js').lengthSync(),
      greaterThan(0),
    );
    expect(
      File('web/vendor/maplibre-gl/maplibre-gl.css').lengthSync(),
      greaterThan(0),
    );
  });

  test('Tauri desktop builds use local Flutter web resources', () {
    final config =
        jsonDecode(File('src-tauri/tauri.conf.json').readAsStringSync())
            as Map<String, dynamic>;
    final build = config['build'] as Map<String, dynamic>;
    expect(build['beforeBuildCommand'], 'npm run build:web:desktop');

    final package =
        jsonDecode(File('package.json').readAsStringSync())
            as Map<String, dynamic>;
    final scripts = package['scripts'] as Map<String, dynamic>;
    expect(scripts['build:web:desktop'], contains('--no-web-resources-cdn'));
    expect(
      scripts['desktop:build:linux'],
      contains('--bundles deb,rpm,appimage'),
    );
  });

  test('release workflow creates Windows and Android update packages', () {
    final workflow = normalizeWorkflow(
      File('.github/workflows/release.yml').readAsStringSync(),
    );
    expect(workflow, contains('runs-on: windows-latest'));
    expect(workflow, contains('flutter build apk --release --no-pub'));
    expect(workflow, contains('tool/check_android_update.sh'));
    expect(workflow, contains('ProjectTabi-$env:GITHUB_REF_NAME-windows-setup.exe'));
    expect(workflow, contains('projecttabi-android'));
    expect(workflow, contains('projecttabi-windows'));
    expect(workflow, contains('generate_release_notes: true'));

    final config = jsonDecode(
      File('src-tauri/tauri.conf.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect((config['bundle'] as Map)['targets'], contains('nsis'));
  });

  test('desktop bootstrap skips service workers inside Tauri', () {
    final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();
    expect(bootstrap, contains("typeof window.__TAURI__ !== 'undefined'"));
    expect(bootstrap, contains('? {}'));
  });

  test('desktop startup remains visible before Flutter initializes', () {
    final index = File('web/index.html').readAsStringSync();
    final monitor = File('web/desktop_startup_monitor.js').readAsStringSync();
    final cleanup = File('web/desktop_cache_cleanup.js').readAsStringSync();

    expect(index, contains('projecttabi-startup-status'));
    expect(monitor, contains("window.addEventListener('error'"));
    expect(monitor, contains("window.addEventListener('unhandledrejection'"));
    expect(cleanup, contains('navigator.serviceWorker.controller'));
    expect(cleanup, contains('window.location.reload()'));
  });
}
