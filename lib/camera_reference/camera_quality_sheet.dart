import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CameraQualityState {
  const CameraQualityState({
    required this.requestedMode,
    required this.activeMode,
    required this.availableModes,
    required this.lensLabel,
    required this.notice,
    required this.outputSize,
    required this.diagnostics,
    this.telephotoAvailable = false,
  });

  final String requestedMode;
  final String activeMode;
  final Set<String> availableModes;
  final String lensLabel;
  final String notice;
  final String outputSize;
  final String diagnostics;
  final bool telephotoAvailable;

  static CameraQualityState? fromPlatform(Object? value) {
    if (value is! Map) return null;
    return CameraQualityState(
      requestedMode: value['requestedMode'] as String? ?? 'auto',
      activeMode: value['activeMode'] as String? ?? 'off',
      availableModes: ((value['availableModes'] as List?) ?? const [])
          .whereType<String>()
          .toSet(),
      lensLabel: value['lensLabel'] as String? ?? '后置自动',
      notice: value['notice'] as String? ?? '',
      outputSize: value['outputSize'] as String? ?? '',
      diagnostics: value['diagnostics'] as String? ?? '',
      telephotoAvailable: value['telephotoAvailable'] == true,
    );
  }

  String get activeLabel => cameraEnhancementLabel(activeMode);
  bool supports(String mode) =>
      mode == 'auto' || mode == 'off' || availableModes.contains(mode);
}

String cameraEnhancementLabel(String mode) => switch (mode) {
  'auto' => '自动增强',
  'hdr' => 'HDR',
  'night' => '夜景',
  _ => '标准',
};

class CameraQualitySheet extends StatefulWidget {
  const CameraQualitySheet({
    required this.state,
    required this.onSelectMode,
    this.onRefresh,
    super.key,
  });

  final CameraQualityState state;
  final Future<CameraQualityState> Function(String) onSelectMode;
  final Future<CameraQualityState> Function()? onRefresh;

  @override
  State<CameraQualitySheet> createState() => _CameraQualitySheetState();
}

class _CameraQualitySheetState extends State<CameraQualitySheet> {
  late CameraQualityState _state = widget.state;
  bool _changing = false;
  String? _error;

  Future<void> _select(String mode) async {
    if (_changing || !_state.supports(mode)) return;
    setState(() {
      _changing = true;
      _error = null;
    });
    try {
      final updated = await widget.onSelectMode(mode);
      if (mounted) setState(() => _state = updated);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _error = error.message ?? '模式切换失败，请重新打开拍摄页。');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '模式切换失败，请重新打开拍摄页。');
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('拍摄画质', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text('当前镜头：${_state.lensLabel} · ${_state.activeLabel}'),
            if (_state.outputSize.isNotEmpty) Text('拍摄分辨率：${_state.outputSize}'),
            Text(_state.telephotoAvailable
                ? '已检测到长焦，可通过拍摄页的“切换镜头”选择。'
                : '未检测到可独立切换的长焦，后置自动的镜头选择由系统决定。'),
            const SizedBox(height: 12),
            for (final mode in const ['auto', 'hdr', 'night', 'off'])
              ListTile(
                contentPadding: EdgeInsets.zero,
                enabled: !_changing && _state.supports(mode),
                title: Text(cameraEnhancementLabel(mode)),
                subtitle: Text(switch (mode) {
                  'auto' => '优先使用手机开放的自动增强或 HDR',
                  'hdr' => _state.supports(mode) ? '适合明暗反差较大的场景' : '当前镜头未提供',
                  'night' => _state.supports(mode) ? '适合暗光场景；拍摄时请保持手机稳定' : '当前镜头未提供',
                  _ => '关闭增强，使用画质优先拍摄',
                }),
                trailing: _state.requestedMode == mode ? const Icon(Icons.check) : null,
                onTap: () => _select(mode),
              ),
            if (_changing) const LinearProgressIndicator(),
            if (_state.notice.isNotEmpty) Text(_state.notice),
            if (_error != null)
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 12),
            const Text('增强功能由手机系统提供，可用模式随镜头和系统版本变化。'),
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('复制相机信息'),
              onPressed: _changing ? null : () async {
                var current = _state;
                try {
                  current = await widget.onRefresh?.call() ?? _state;
                } catch (_) {
                  // Keep the last known information if the camera has closed.
                }
                if (!context.mounted) return;
                setState(() => _state = current);
                await Clipboard.setData(ClipboardData(text: current.diagnostics));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('相机信息已复制，可用于反馈画质问题。')),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
