import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'camera_preferences.dart';
import 'camera_quality_sheet.dart';

class CameraQualitySettings extends StatefulWidget {
  const CameraQualitySettings({super.key});

  @override
  State<CameraQualitySettings> createState() => _CameraQualitySettingsState();
}

class _CameraQualitySettingsState extends State<CameraQualitySettings> {
  final preferences = CameraPreferences.instance;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    preferences.load().then((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  Future<void> _select(String mode) async {
    if (_loading || _saving) return;
    setState(() { _saving = true; _error = null; });
    try {
      await preferences.select(mode);
    } catch (_) {
      if (mounted) setState(() => _error = '画质设置未能保存，请检查存储空间后重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: preferences,
    builder: (context, _) {
      final last = preferences.lastQuality;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('下次进入拍摄时生效。手机或镜头不支持所选增强时，自动使用标准拍摄。'),
        for (final mode in const ['auto', 'hdr', 'night', 'off'])
          ListTile(
            contentPadding: EdgeInsets.zero,
            enabled: !_loading && !_saving,
            title: Text(cameraEnhancementLabel(mode)),
            subtitle: Text(switch (mode) {
              'auto' => '优先使用手机开放的自动增强或 HDR',
              'hdr' => '适合明暗反差较大的场景',
              'night' => '适合暗光场景，拍摄时需保持稳定',
              _ => '使用画质优先拍摄，关闭厂商扩展增强',
            }),
            trailing: preferences.mode == mode ? const Icon(Icons.check) : null,
            onTap: () => _select(mode),
          ),
        if (_loading || _saving) const LinearProgressIndicator(),
        if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        const Divider(),
        Text('上次拍摄的相机信息', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (last == null)
          const Text('使用一次拍摄功能后，可在这里查看镜头、增强支持和分辨率。')
        else ...[
          Text('${last.lensLabel} · ${last.activeLabel}'),
          Text('拍摄分辨率：${last.outputSize}'),
          Text(last.telephotoAvailable ? '已检测到可访问的长焦镜头' : '未检测到可独立切换的长焦镜头'),
          Text('可用增强：${last.availableModes.isEmpty ? '无' : last.availableModes.map(cameraEnhancementLabel).join('、')}'),
          if (last.notice.isNotEmpty) Text(last.notice),
          TextButton.icon(
            icon: const Icon(Icons.copy), label: const Text('复制相机信息'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text:
                '记录时间：${preferences.observedAt ?? '未知'}\n${last.diagnostics}'));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('相机信息已复制')));
            },
          ),
        ],
      ]);
    },
  );
}
