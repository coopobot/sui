/// 远端账号操作：注册 / 登录 / 刷新令牌 / 连通性探测。
///
/// 与 [SyncClient] 分开：同步需要令牌，而这里正是**取得与续期**令牌的地方，
/// 因此不能依赖已鉴权的 [SyncClient]。
///
/// M10（FR-49 / auth.md §8.2~§8.3）：服务端签发「短时访问令牌 + 可撤销刷新令牌」，
/// 本类负责把两者交给调用方持久化，并在访问令牌过期时用刷新令牌换新的一对。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sync_client.dart' show HttpException;

/// 一次账号会话的令牌对（M10/FR-49）。
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    this.expiresIn = 0,
  });

  /// 访问令牌（短时有效，用于 `Authorization: Bearer`）。
  final String accessToken;

  /// 刷新令牌（**只能**用于 `/api/v1/refresh`；单次使用，换发即失效）。
  final String refreshToken;

  /// 访问令牌剩余有效秒数（服务端下发；0 表示未知）。
  final int expiresIn;

  bool get hasRefresh => refreshToken.isNotEmpty;

  @override
  String toString() =>
      'AuthSession(access: ${accessToken.isEmpty ? '(空)' : '***'}, refresh: ${refreshToken.isEmpty ? '(空)' : '***'}, expiresIn: $expiresIn)';
}

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

  /// 注册新账号，返回令牌对。
  Future<AuthSession> register({
    required String baseUrl,
    required String username,
    required String password,
  }) =>
      _session('/api/v1/register', baseUrl, username, password);

  /// 登录已有账号，返回令牌对。
  Future<AuthSession> login({
    required String baseUrl,
    required String username,
    required String password,
  }) =>
      _session('/api/v1/login', baseUrl, username, password);

  /// 以刷新令牌换发新的一对令牌（M10/FR-49）。
  ///
  /// 调用方收到 401 `token-expired` 时调用；**必须并发去重（单飞）**——刷新是单次使用 +
  /// 轮换，同一枚刷新令牌被用两次会被服务端判定为重放并**吊销整个会话**（auth.md §8.3）。
  Future<AuthSession> refresh({
    required String baseUrl,
    required String refreshToken,
  }) async {
    final uri = Uri.parse('${_norm(baseUrl)}/api/v1/refresh');
    final resp = await _http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh_token': refreshToken}),
    );
    if (resp.statusCode != 200) {
      throw HttpException(resp.statusCode, _errorOf(resp.body));
    }
    return _parseSession(resp);
  }

  Future<AuthSession> _session(
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
    return _parseSession(resp);
  }

  /// 解析令牌响应。
  ///
  /// 优先 `access_token`（M10 口径）；回落旧的 `token` 字段（服务端为兼容旧客户端临时保留），
  /// 此时刷新令牌可能缺失——调用方据此降级为「过期即提示重新登录」。
  AuthSession _parseSession(http.Response resp) {
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final access = (data['access_token'] as String?) ?? (data['token'] as String?) ?? '';
    if (access.isEmpty) {
      throw HttpException(resp.statusCode, '响应中缺少 access_token');
    }
    final refresh = (data['refresh_token'] as String?) ?? '';
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 0;
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresIn: expiresIn,
    );
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
