/// 同步配置：本机连接服务端所需的最小信息。
///
/// 全部为本机设备级设置（不参与同步、不需要跨端一致）：
/// - [baseUrl]：服务端根地址，如 `http://127.0.0.1:8080`（末尾斜杠会被去掉）
/// - [token]：Bearer Token（注册或登录后由服务端下发）
/// - [deviceId]：本机设备标识，首次运行生成并持久化，用于来源标记与冲突归因
class SyncConfig {
  const SyncConfig({
    this.baseUrl = '',
    this.token = '',
    this.deviceId = '',
  });

  final String baseUrl;
  final String token;
  final String deviceId;

  /// 是否具备发起同步的条件（地址 + Token 均已填写）。
  bool get isConfigured => baseUrl.trim().isNotEmpty && token.trim().isNotEmpty;

  /// 规范化地址：去掉末尾斜杠，避免拼出 `//api/v1/...`。
  static String normalizeBaseUrl(String raw) {
    var v = raw.trim();
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  SyncConfig copyWith({String? baseUrl, String? token, String? deviceId}) =>
      SyncConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        token: token ?? this.token,
        deviceId: deviceId ?? this.deviceId,
      );

  @override
  String toString() =>
      'SyncConfig(baseUrl: $baseUrl, deviceId: $deviceId, token: ${token.isEmpty ? '(空)' : '***'})';
}