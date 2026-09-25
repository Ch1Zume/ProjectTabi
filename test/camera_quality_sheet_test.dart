import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_tabi/camera_reference/camera_quality_sheet.dart';

CameraQualityState state({String requested = 'auto', String active = 'off', List<String> modes = const []}) =>
    CameraQualityState.fromPlatform({
      'requestedMode': requested,
      'activeMode': active,
      'availableModes': modes,
      'lensLabel': '后置自动',
      'outputSize': '4096 × 3072',
      'notice': active == 'off' ? '当前镜头未提供可用增强，使用画质优先拍摄。' : '',
      'diagnostics': 'test camera',
    })!;

void main() {
  test('missing native capability data does not claim enhancement support', () {
    expect(CameraQualityState.fromPlatform(null), isNull);
    final quality = state();
    expect(quality.activeLabel, '标准');
    expect(quality.supports('auto'), isTrue);
    expect(quality.supports('hdr'), isFalse);
    expect(quality.supports('night'), isFalse);
  });

  testWidgets('unsupported modes cannot be selected and actual fallback is shown', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CameraQualitySheet(
      state: state(),
      onSelectMode: (_) async { calls++; return state(); },
    ))));
    expect(find.text('当前镜头：后置自动 · 标准'), findsOneWidget);
    await tester.tap(find.text('HDR'));
    await tester.pump();
    expect(calls, 0);
    expect(find.text('当前镜头未提供'), findsNWidgets(2));
  });

  testWidgets('waits for the camera before reporting enhancement as active', (tester) async {
    final pending = Completer<CameraQualityState>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CameraQualitySheet(
      state: state(modes: ['hdr']),
      onSelectMode: (_) { calls++; return pending.future; },
    ))));
    await tester.tap(find.text('HDR'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('当前镜头：后置自动 · 标准'), findsOneWidget);
    await tester.tap(find.text('自动增强'));
    expect(calls, 1);
    pending.complete(state(requested: 'hdr', active: 'hdr', modes: ['hdr']));
    await tester.pumpAndSettle();
    expect(find.text('当前镜头：后置自动 · HDR'), findsOneWidget);
  });

  testWidgets('quality controls scroll on a short landscape screen', (tester) async {
    tester.view.physicalSize = const Size(720, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CameraQualitySheet(
      state: state(), onSelectMode: (_) async => state(),
    ))));
    await tester.scrollUntilVisible(find.text('复制相机信息'), 100);
    expect(tester.takeException(), isNull);
    expect(find.text('复制相机信息').hitTestable(), findsOneWidget);
  });
}
