/// 远端账号操作：注册 / 登录 / 连通性探测。
///
/// 与 [SyncClient] 分开：同步需要 Token，而这里正是**取得** Token 的地方，
/// 因此不能依赖已鉴权的 [SyncClient]。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync_client.dart' show HttpException;

class AuthClient {
  AuthClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final http.Client _http;

  /// 探测服务端是否可达，成功返回服务端上报的版本号。
  Future<String> ping(String baseUrl) async => (await pingInfo(baseUrl)).version;

  /// 探测服务端：返回版本号与 `initialized`（M4/BR-33.4）。
  ///
  /// `initialized=true` 表示该实例已完成首启建号、自助注册永久关闭，
  /// 客户端应引导用户走「登录」而不是「注册」。
  Future<({String version, bool initialized})> pingInfo(String baseUrl) async {
    final uri = Uri.parse('${_norm(baseUrl)}/api/v1/ping');
    final resp = await _http.get(uri);
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, resp.body);
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (
      version: (data['version'] as String?) ?? '',
      initialized: (data['initialized'] as bool?) ?? false,
    );
  }

  /// 注册新账号，返回 Token。
  Future<String> register({
    required String baseUrl,
    required String username,
    required String password,
  }) =>
      _token('/api/v1/register', baseUrl, username, password);

  /// 登录已有账号，返回 Token。
  Future<String> login({
    required String baseUrl,
    required String username,
    required String password,
  }) =>
      _token('/api/v1/login', baseUrl, username, password);

  Future<String> _token(
    String path,
    String baseUrl,
    String username,
    String password,
  ) async {
    final uri = Uri.parse('${_norm(baseUrl)}$path');
    final resp = await _http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'username': username, 'password': password}),
    );
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, _errorOf(resp.body));
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = data['token'] as String?;
    if (token == null || token.isEmpty) {
      throw HttpException(resp.statusCode, '响应中缺少 token');
    }
    return token;
  }

  /// 优先取服务端返回的 `error` 字段，便于 UI 直接展示。
  String _errorOf(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final msg = data['error'] as String?;
      if (msg != null && msg.isNotEmpty) return msg;
    } on FormatException {
      // 非 JSON（如网关返回的 HTML），原样返回。
    }
    return body;
  }

  static String _norm(String baseUrl) {
    var v = baseUrl.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  void close() => _http.close();
}