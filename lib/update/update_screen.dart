import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'update_controller.dart';

class AppUpdateScreen extends StatefulWidget {
  const AppUpdateScreen({super.key});
  @override
  State<AppUpdateScreen> createState() => _AppUpdateScreenState();
}

class _AppUpdateScreenState extends State<AppUpdateScreen> {
  final controller = AppUpdateController.instance;
  @override
  void initState() {
    super.initState();
    controller.initialize();
  }

  Future<void> _install() async {
    final confirm = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('安装更新'),
      content: const Text('更新将关闭应用。已保存的记录、照片和同步设置会保留。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('稍后')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('立即更新')),
      ],
    ));
    if (confirm == true && mounted) await controller.install();
  }

  String _size(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('应用更新')),
    body: AnimatedBuilder(animation: controller, builder: (context, _) {
      final c = controller;
      final downloading = {'downloading', 'waiting', 'verifying'}.contains(c.phase);
      return ListView(padding: const EdgeInsets.all(20), children: [
        Text('ProjectTabi', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text('当前版本：${c.currentVersion.replaceFirst('+', ' · 构建 ')}'),
        if (c.hasUpdate) Text('可用版本：${c.version!.replaceFirst('+', ' · 构建 ')}'),
        const SizedBox(height: 16),
        Text(switch (c.phase) {
          'checking' => '正在检查新版本…',
          'current' => '已经是最新版本',
          'available' => '有新版本可用',
          'downloading' => '正在下载更新…',
          'waiting' => '等待 Wi-Fi 或网络恢复，下载会自动继续',
          'verifying' => '正在校验安装包…',
          'ready' => '下载完成，安装包校验通过',
          'installing' => '已打开系统安装程序；取消后可重新点击安装',
          _ => c.supported ? '检查并下载最新更新' : '此平台请使用手动下载',
        }),
        if (downloading) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: c.total > 0 && c.phase == 'downloading'
              ? (c.downloaded / c.total).clamp(0.0, 1.0) : null),
          const SizedBox(height: 8),
          Text('${_size(c.downloaded)} / ${c.total > 0 ? _size(c.total) : '正在获取大小'}'),
        ] else if (c.hasUpdate && c.total > 0) Text('下载大小：${_size(c.total)}'),
        if (c.error != null) ...[
          const SizedBox(height: 12),
          Text(c.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 16),
        Wrap(spacing: 12, runSpacing: 8, children: [
          if (c.hasUpdate && !downloading && c.phase != 'ready')
            OutlinedButton(onPressed: c.busy ? null : () => c.check(), child: const Text('重新检查')),
          if (c.phase == 'ready')
            FilledButton(onPressed: c.busy ? null : _install, child: const Text('安装更新'))
          else if (downloading)
            OutlinedButton(onPressed: c.phase == 'verifying' ? null : c.cancelDownload, child: const Text('取消下载'))
          else if (c.hasUpdate && c.phase != 'checking')
            FilledButton(onPressed: c.busy ? null : () => c.startDownload(), child: const Text('下载更新／重试'))
          else
            FilledButton(onPressed: c.busy || !c.supported ? null : () => c.check(), child: const Text('检查更新')),
          TextButton(onPressed: () async {
            try {
              final opened = await launchUrl(Uri.parse('https://github.com/Ch1Zume/ProjectTabi/releases'), mode: LaunchMode.externalApplication);
              if (!opened) throw StateError('open failed');
            } catch (_) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法打开浏览器，请手动访问 GitHub 中的 ProjectTabi Releases。')));
            }
          }, child: const Text('手动下载')),
        ]),
        const Divider(height: 36),
        SwitchListTile(contentPadding: EdgeInsets.zero,
          title: const Text('自动检查更新'), subtitle: const Text('打开应用时检查，每天最多一次'),
          value: c.autoCheck, onChanged: c.supported ? (v) => c.savePreferences(check: v) : null),
        SwitchListTile(contentPadding: EdgeInsets.zero,
          title: const Text('仅 Wi-Fi 自动下载'), subtitle: const Text('发现更新后下载，安装前仍会提醒'),
          value: c.wifiAutoDownload, onChanged: c.supported && !downloading ? (v) => c.savePreferences(download: v) : null),
        if (c.notes.isNotEmpty) ...[
          const Divider(height: 36),
          Text('更新内容', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SelectableText(c.notes),
        ],
      ]);
    }),
  );
}
