import 'dart:async';
import 'sync_snapshot.dart';
import 'webdav_client.dart';

class SyncFailure {
  const SyncFailure(
    this.code,
    this.reason,
    this.action, {
    this.stage = '',
    this.state = '',
    this.localDataChanged = false,
  });
  final String code, reason, action, stage, state;
  final bool localDataChanged;

  factory SyncFailure.describe(
    Object error, {
    String stage = '',
    bool cloudWriteStarted = false,
    bool cloudCommitted = false,
    bool localCommitted = false,
  }) {
    String code, reason, action;
    if (error is WebDavFailure) {
      code = error.code;
      reason = error.reason;
      action = error.action;
    } else if (error is SyncAssetReadException) {
      code = 'LOCAL_IMAGE';
      reason = error.toString();
      action = '检查提示中的记录及文件路径；恢复原文件或重新导入完整备份后重试。';
    } else if (error is SyncChangedRemotely) {
      code = 'CLOUD_CHANGED';
      reason = '另一台设备更新了云端版本。';
      action = '重新读取两端版本，再选择同步方向。';
    } else if (error is TimeoutException) {
      code = 'TIMEOUT';
      reason = '连接或传输超时。';
      action = '检查网络和服务器是否可访问，稍后重试。';
    } else if (error is FormatException) {
      code = 'INVALID_DATA';
      reason = error.message;
      action = '检查服务器地址或恢复有效的同步备份；不要删除当前数据。';
    } else if (error is TypeError) {
      code = 'INVALID_DATA';
      reason = '同步数据的字段格式不正确或版本不兼容。';
      action = '保留现有数据，检查两端应用版本，或恢复有效的同步备份。';
    } else if (error is StateError) {
      code = 'STATE_CHANGED';
      reason = error.message.toString();
      action = '关闭其他同步任务，重新读取两端版本后重试。';
    } else {
      final text = error.toString().toLowerCase();
      code = 'LOCAL_STORAGE';
      reason =
          text.contains('space') ||
              text.contains('disk full') ||
              text.contains('磁盘')
          ? '设备存储空间不足。'
          : text.contains('permission') || text.contains('access denied')
          ? '设备拒绝访问数据目录。'
          : '读取或保存本地数据失败。';
      action = '检查剩余空间和应用数据目录的读写权限，再重试；错误类型：${error.runtimeType}。';
    }
    final state = localCommitted
        ? '记录已保存，但同步状态未完全保存；重试前请刷新版本。'
        : cloudCommitted
        ? '云端已保存，本地尚未完成；本地原记录和同步前备份仍保留。'
        : cloudWriteStarted
        ? '未覆盖本地记录；云端写入结果待确认，请先刷新版本。'
        : '未覆盖两端记录。';
    return SyncFailure(code, reason, action, stage: stage, state: state,
        localDataChanged: localCommitted);
  }

  String get message => [
    if (stage.isNotEmpty) '同步停止：$stage',
    reason,
    action,
    if (state.isNotEmpty) state,
    '错误代码：$code',
  ].join('\n');
}
