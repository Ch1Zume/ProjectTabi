import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'sync_failure.dart';
import '../data/pilgrimage_repository.dart';
import 'sync_merge.dart';
import 'sync_platform.dart';
import 'sync_service.dart';
import 'webdav_client.dart';

Future<void> _openSyncIssuePage() async {
  await launchUrl(
    Uri.parse('https://github.com/Ch1Zume/ProjectTabi/issues/new'),
    mode: LaunchMode.externalApplication,
  );
}

class WebDavSettingsScreen extends StatefulWidget {
  const WebDavSettingsScreen({
    required this.repository,
    this.autoStart = false,
    super.key,
  });
  final PilgrimageRepository repository;
  final bool autoStart;
  @override
  State<WebDavSettingsScreen> createState() => _WebDavSettingsScreenState();
}

class _WebDavSettingsScreenState extends State<WebDavSettingsScreen> {
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _folder = TextEditingController(text: 'MiriaGoSync');
  bool _busy = true, _remember = true, _auto = false, _changed = false;
  String _status = '正在读取设置…';
  String? _lastSync;
  List<SyncHistoryEntry> _history = const [];
  SyncPreview? _preview;
  SyncFailure? _failure;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_url, _username, _password, _folder]) {
      c.dispose();
    }
    super.dispose();
  }

  WebDavConfig _config() => WebDavConfig(
    url: _url.text,
    username: _username.text.trim(),
    folder: _folder.text.trim(),
  );
  Future<void> _load() async {
    try {
      final stored = await syncStoreRead('config');
      if (stored != null) {
        final config = jsonDecode(stored) as Map;
        _url.text = config['url'] as String;
        _username.text = config['username'] as String;
        _folder.text = config['folder'] as String;
        _remember = config['remember'] == true;
        _auto = config['auto'] == true;
        final key = syncAccountKey(_config());
        if (_remember) _password.text = await syncReadPassword(key) ?? '';
        _lastSync = await syncStoreRead('last_sync_$key');
        _history = await readSyncHistory(key);
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '就绪';
      });
      if (widget.autoStart && _password.text.isNotEmpty) await _run(sync: true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '无法读取保存的设置或密码，请重新填写。';
        });
      }
    }
  }

  Future<void> _save(WebDavConfig config) async {
    await syncWritePassword(
      syncAccountKey(config),
      _remember ? _password.text : '',
    );
    await syncStoreWrite(
      'config',
      jsonEncode({
        'url': config.url.toString(),
        'username': config.username,
        'folder': config.folder,
        'remember': _remember,
        'auto': _auto && _remember,
      }),
    );
  }

  Future<void> _run({required bool sync}) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _status = sync ? '读取版本…' : '检查连接…';
      _failure = null;
    });
    WebDavClient? client;
    SyncService? service;
    try {
      final config = _config();
      client = WebDavClient(config, _password.text);
      service = SyncService(widget.repository, client);
      if (sync) {
        await _save(config);
        final success = await service.synchronize(
          resolve: _resolve,
          chooseDirection: _chooseDirection,
          progress: (s) {
            if (mounted) setState(() => _status = s);
          },
        );
        _changed = _changed || success;
        if (!success && mounted) setState(() => _status = '已取消同步，记录未更改。');
        _lastSync = await syncStoreRead('last_sync_${syncAccountKey(config)}');
        if (success) {
          _preview = null;
          try {
            _preview = await service.inspect();
          } on Exception {
            /* Sync already completed. */
          }
        }
      } else {
        _preview = await service.inspect();
        await _save(config);
        if (mounted) setState(() => _status = '连接正常，已刷新版本。');
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _failure =
              service?.lastFailure ??
              SyncFailure.describe(error, stage: _status);
          _changed = _changed || _failure!.localDataChanged;
          _status = _failure!.message;
        });
      }
    } finally {
      if (service != null) _history = await service.loadHistory();
      client?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _time(DateTime? time) {
    if (time == null) return '旧版本未记录';
    final t = time.toLocal();
    String n(int value) => value.toString().padLeft(2, '0');
    return '${t.year}-${n(t.month)}-${n(t.day)} ${n(t.hour)}:${n(t.minute)}:${n(t.second)}';
  }

  Widget _versions(SyncPreview p) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '本地更新：${_time(p.localUpdatedAt)}${p.localTimeEstimated ? '（旧数据估算）' : ''}',
      ),
      Text('${p.localPlans} 个计划 · ${p.localRecords} 条记录'),
      const SizedBox(height: 12),
      Text('云端更新：${p.hasRemote ? _time(p.remoteUpdatedAt) : '暂无数据'}'),
      Text('${p.remotePlans} 个计划 · ${p.remoteRecords} 条记录'),
    ],
  );

  Future<SyncDirection?> _chooseDirection(SyncPreview preview) async {
    if (!mounted) return null;
    setState(() => _preview = preview);
    return showDialog<SyncDirection>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择同步方向'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _versions(preview),
                const Divider(height: 32),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('本地 → 云端'),
                  subtitle: const Text('保留本地，覆盖云端全部计划和记录'),
                  onTap: () => Navigator.pop(context, SyncDirection.upload),
                ),
                ListTile(
                  enabled: preview.hasRemote,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_download_outlined),
                  title: const Text('云端 → 本地'),
                  subtitle: const Text('保留云端，覆盖本地全部计划和记录'),
                  onTap: preview.hasRemote
                      ? () => Navigator.pop(context, SyncDirection.download)
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<Map<String, bool>?> _resolve(List<SyncConflict> conflicts) async {
    final choices = <String, bool>{};
    for (var i = 0; i < conflicts.length; i++) {
      if (!mounted) return null;
      final c = conflicts[i];
      String preview(Object? v) {
        if (v == null) return '已删除';
        final text = const JsonEncoder.withIndent('  ').convert(v);
        return text.length > 3000 ? '${text.substring(0, 3000)}…' : text;
      }

      final choice = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text('同步冲突 ${i + 1}/${conflicts.length}'),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('两端都修改了这项内容。请选择保留的版本，或取消后整理再试。'),
                  const SizedBox(height: 12),
                  Text(c.path.split('/').map(Uri.decodeComponent).join(' / ')),
                  const Divider(),
                  const Text('此设备'),
                  SelectableText(preview(c.local)),
                  const Divider(),
                  const Text('云端'),
                  SelectableText(preview(c.remote)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消同步'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留此设备'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保留云端'),
            ),
          ],
        ),
      );
      if (choice == null) return null;
      choices[c.path] = choice;
    }
    return choices;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV 同步'),
        leading: IconButton(
          onPressed: _busy ? null : () => Navigator.pop(context, _changed),
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              TextField(
                controller: _url,
                onChanged: (_) => setState(() {
                  _preview = null;
                  _lastSync = null;
                }),
                enabled: !_busy,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 地址',
                  hintText: 'https://服务器/dav/',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                onChanged: (_) => setState(() {
                  _preview = null;
                  _lastSync = null;
                }),
                enabled: !_busy,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '账号'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '应用密码'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _folder,
                onChanged: (_) => setState(() {
                  _preview = null;
                  _lastSync = null;
                }),
                enabled: !_busy,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '同步文件夹'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('安全保存密码'),
                value: _remember,
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _remember = v;
                        if (!v) _auto = false;
                      }),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('回到前台时提醒同步'),
                value: _auto,
                onChanged: _busy || !_remember
                    ? null
                    : (v) => setState(() => _auto = v),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy ? null : () => _run(sync: false),
                    child: const Text('保存并刷新版本'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _run(sync: true),
                    icon: const Icon(Icons.sync),
                    label: const Text('选择同步方向'),
                  ),
                ],
              ),
              if (_busy) ...[
                const SizedBox(height: 20),
                const LinearProgressIndicator(),
              ],
              const SizedBox(height: 16),
              if (_preview != null) ...[
                _versions(_preview!),
                const SizedBox(height: 16),
              ],
              SelectableText(_status),
              if (_failure != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(text: _failure!.message),
                        ),
                        icon: const Icon(Icons.copy),
                        label: const Text('复制错误详情'),
                      ),
                      TextButton.icon(
                        onPressed: _openSyncIssuePage,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('前往反馈'),
                      ),
                    ],
                  ),
                ),
              if (_lastSync != null) ...[
                const SizedBox(height: 8),
                Text('上次同步：${_time(DateTime.tryParse(_lastSync!))}'),
              ],
              if (_history.isNotEmpty) ...[
                const Divider(height: 32),
                Text(
                  '同步记录',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final entry in _history.take(10))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      entry.status == 'success'
                          ? Icons.check_circle_outline
                          : entry.status == 'failed'
                          ? Icons.error_outline
                          : Icons.remove_circle_outline,
                    ),
                    title: Text(
                      '${entry.directionLabel} · ${entry.statusLabel}',
                    ),
                    subtitle: Text(
                      '开始：${_time(entry.startedAt)} · 完成：${_time(entry.completedAt)}'
                      '${entry.summary.isEmpty ? '' : ' · ${entry.summary}'}',
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
