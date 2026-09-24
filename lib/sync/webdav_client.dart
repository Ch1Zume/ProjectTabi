import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'sync_platform.dart';

class WebDavConfig {
  WebDavConfig({
    required String url,
    required this.username,
    this.folder = 'MiriaGoSync',
  }) : url = validateUrl(url);
  final Uri url;
  final String username;
  final String folder;
  static Uri validateUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入完整的 HTTPS WebDAV 地址。');
    }
    if (uri.path.endsWith('/browser/') || uri.path.endsWith('/browser')) {
      throw const FormatException(
        '这是网页地址，请从 My Page 复制 WebDAV Connection URL。',
      );
    }
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }

  String get identity => jsonEncode([url.toString(), username, folder]);
}

class DavResponse {
  const DavResponse(this.status, this.bytes, this.etag);
  final int status;
  final List<int> bytes;
  final String? etag;
}

class SyncChangedRemotely implements Exception {
  @override
  String toString() => '另一台设备刚刚更新了云端，请重新同步。';
}

class WebDavFailure implements Exception {
  const WebDavFailure(this.code, this.reason, this.action);
  final String code, reason, action;
  @override
  String toString() => '$reason\n$action（$code）';
}

class WebDavClient {
  WebDavClient(this.config, this.password, {http.Client? client})
    : _client = client ?? http.Client() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(config.folder)) {
      throw const FormatException('同步文件夹只能包含英文字母、数字、下划线和连字符。');
    }
    if (config.username.isEmpty ||
        config.username.contains(':') ||
        password.isEmpty) {
      throw const FormatException('请填写 Connection ID 和 Apps Password。');
    }
  }
  final WebDavConfig config;
  final String password;
  final http.Client _client;
  void close() => _client.close();
  Future<DavResponse> request(
    String method,
    String path, {
    List<int> body = const [],
    Map<String, String> headers = const {},
    bool root = false,
  }) async {
    if (path.contains('..') || path.startsWith('/') || path.contains('://')) {
      throw const FormatException('无效的同步路径。');
    }
    final uri = config.url.resolve(root ? '' : '${config.folder}/$path');
    final allHeaders = {
      'Authorization':
          'Basic ${base64Encode(utf8.encode('${config.username}:$password'))}',
      ...headers,
    };
    try {
      if (syncUsesDesktop) {
        final result = await syncDesktopRequest(
          uri.toString(),
          method,
          allHeaders,
          body,
        );
        return DavResponse(
          result['status'] as int,
          base64Decode(result['body'] as String),
          result['etag'] as String?,
        );
      }
      final req = http.Request(method, uri)
        ..followRedirects = false
        ..headers.addAll(allHeaders)
        ..bodyBytes = body;
      final response = await _client
          .send(req)
          .timeout(const Duration(seconds: 90));
      final limit = path.startsWith('objects/')
          ? 128 * 1024 * 1024
          : 32 * 1024 * 1024;
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 90),
      )) {
        if (bytes.length + chunk.length > limit) {
          throw const FormatException('云端文件过大。');
        }
        bytes.addAll(chunk);
      }
      return DavResponse(response.statusCode, bytes, response.headers['etag']);
    } on FormatException {
      rethrow;
    } on TimeoutException {
      throw WebDavFailure('TIMEOUT', '$method 请求超时。', '检查网络或服务器响应速度后重试。');
    } catch (error) {
      final detail = error.toString().toLowerCase();
      final certificate =
          detail.contains('certificate') ||
          detail.contains('handshake') ||
          detail.contains('tls');
      final dns =
          detail.contains('host lookup') ||
          detail.contains('dns') ||
          detail.contains('resolve host');
      throw WebDavFailure(
        certificate
            ? 'TLS'
            : dns
            ? 'DNS'
            : 'NETWORK',
        certificate
            ? '服务器安全证书验证失败。'
            : dns
            ? '无法解析服务器地址。'
            : '$method 网络连接失败。',
        certificate
            ? '检查手机时间及服务器 HTTPS 证书，不要关闭证书验证。'
            : dns
            ? '检查 WebDAV 域名、DNS 和网络连接。'
            : '检查网络、代理设置以及 WebDAV 服务器是否可访问。',
      );
    }
  }

  void check(DavResponse r, Set<int> allowed) {
    if (allowed.contains(r.status)) return;
    if (r.status == 412) throw SyncChangedRemotely();
    const failures = <int, List<String>>{
      401: [
        'AUTH',
        '账号或应用密码未通过验证。',
        '检查 Connection ID 和 Apps Password，确认没有使用网页登录密码。',
      ],
      403: ['FORBIDDEN', '服务器拒绝访问同步目录。', '检查 Apps Connection 是否启用，以及目录读写权限。'],
      404: ['NOT_FOUND', '服务器上的同步文件不存在。', '检查 WebDAV 地址和同步文件夹；缺失图片可从原设备重新上传。'],
      405: [
        'METHOD',
        '服务器不支持所需的 WebDAV 操作。',
        '确认填写的是 WebDAV 接口，而不是 browser 网页地址。',
      ],
      409: ['DIRECTORY', '同步目录的父目录不存在。', '检查 WebDAV 根路径和同步文件夹配置。'],
      413: ['TOO_LARGE', '服务器拒绝接收过大的文件。', '检查服务器单文件大小限制。'],
      423: ['LOCKED', '云端文件被锁定。', '等待另一设备完成同步，或检查服务器文件锁。'],
      429: ['RATE_LIMIT', '服务器请求过于频繁。', '等待一会儿后重试。'],
      507: ['CLOUD_FULL', '云端可用空间不足。', '清理云盘空间或增加容量后重试。'],
    };
    final failure = failures[r.status];
    throw WebDavFailure(
      failure?[0] ?? 'HTTP_${r.status}',
      '${failure?[1] ?? '服务器暂时无法完成请求。'}（HTTP ${r.status}）',
      failure?[2] ?? '检查服务器状态后重试。',
    );
  }

  Future<void> testConnection() async {
    check(
      await request(
        'PROPFIND',
        '',
        root: true,
        headers: {
          'Depth': '0',
          'Content-Type': 'application/xml; charset=utf-8',
        },
        body: utf8.encode(
          '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
        ),
      ),
      {207},
    );
  }

  Future<void> prepare() async {
    await testConnection();
    for (final path in ['', 'objects/']) {
      check(await request('MKCOL', path), {201, 405});
    }
  }

  Future<bool> putObject(String name, List<int> bytes) async {
    final existing = await request('HEAD', 'objects/$name');
    if (existing.status == 200) return false;
    check(existing, {404});
    final uploaded = await request(
      'PUT',
      'objects/$name',
      body: bytes,
      headers: {
        'If-None-Match': '*',
        'Content-Type': 'application/octet-stream',
      },
    );
    check(uploaded, {200, 201, 204, 412});
    return uploaded.status != 412;
  }

  Future<void> backupManifest(List<int> bytes) async {
    check(await request('MKCOL', 'history/'), {201, 405});
    final hash = sha256.convert(bytes).toString();
    check(
      await request(
        'PUT',
        'history/$hash.json',
        body: bytes,
        headers: {'If-None-Match': '*', 'Content-Type': 'application/json'},
      ),
      {200, 201, 204, 412},
    );
  }

  Future<void> putManifest(
    List<int> bytes,
    String? etag, {
    required bool exists,
  }) async {
    if (exists &&
        (etag == null || etag.startsWith('W/') || !etag.startsWith('"'))) {
      throw const WebDavFailure(
        'ETAG_REQUIRED',
        '服务器未提供可靠的版本标识（强 ETag）。',
        '检查 WebDAV 服务或代理是否保留 ETag；已停止覆盖云端。',
      );
    }
    check(
      await request(
        'PUT',
        'manifest-v1.json',
        body: bytes,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          if (exists) 'If-Match': etag! else 'If-None-Match': '*',
        },
      ),
      {200, 201, 204},
    );
  }
}
