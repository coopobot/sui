import '../db/app_database.dart';
import '../models/sync_config.dart';
import '../util/ids.dart';

/// 应用级键值配置的读写入口（落本地 SQLite，重启保留）。
///
/// 目前承载「如何连服务端」这类设备级设置，见 [SyncConfig]。
class SettingsStore {
  SettingsStore(this._db);

  final AppDatabase _db;

  static const _kBaseUrl = 'sync.baseUrl';
  static const _kToken = 'sync.token';
  static const _kRefreshToken = 'sync.refreshToken';
  static const _kDeviceId = 'device.id';
  static const _kCacheLimit = 'blob.cacheLimitBytes';

  Future<String?> get(String key) async {
    final row = await (_db.select(_db.settings)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> set(String key, String value) async {
    await _db.into(_db.settings).insertOnConflictUpdate(
          SettingsCompanion.insert(key: key, value: value),
        );
  }

  Future<void> remove(String key) async {
    await (_db.delete(_db.settings)..where((t) => t.key.equals(key))).go();
  }

  /// 本机设备标识：首次调用生成并持久化，之后恒定不变。
  Future<String> deviceId() async {
    final existing = await get(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = newId();
    await set(_kDeviceId, id);
    return id;
  }

  /// 读取同步配置（未设置时返回空值，[SyncConfig.isConfigured] 为 false）。
  Future<SyncConfig> loadSyncConfig() async {
    final baseUrl = await get(_kBaseUrl) ?? '';
    final token = await get(_kToken) ?? '';
    final refreshToken = await get(_kRefreshToken) ?? '';
    return SyncConfig(
      baseUrl: baseUrl,
      token: token,
      refreshToken: refreshToken,
      deviceId: await deviceId(),
    );
  }

  /// 保存同步配置。[baseUrl] 会做规范化（去末尾斜杠）。
  ///
  /// [refreshToken] 缺省为空串：既有调用点（含测试）无需改动；令牌刷新成功后由调用方
  /// 用新值再次保存（M10/FR-49）。
  Future<void> saveSyncConfig({
    required String baseUrl,
    required String token,
    String refreshToken = '',
  }) async {
    await set(_kBaseUrl, SyncConfig.normalizeBaseUrl(baseUrl));
    await set(_kToken, token.trim());
    await set(_kRefreshToken, refreshToken.trim());
  }

  /// 断开连接：清掉地址与两个令牌，保留 deviceId。
  ///
  /// **刷新令牌必须一并删除**——否则「断开」之后仍残留一枚长期凭证（M10/BR-49.4）。
  Future<void> clearSyncConfig() async {
    await remove(_kBaseUrl);
    await remove(_kToken);
    await remove(_kRefreshToken);
  }

  /// 附件缓存上限（字节）。未设置或值非法时返回 [fallback]。
  Future<int> cacheLimitBytes({int fallback = 512 * 1024 * 1024}) async {
    final raw = await get(_kCacheLimit);
    final parsed = int.tryParse(raw ?? '');
    return (parsed == null || parsed <= 0) ? fallback : parsed;
  }

  Future<void> setCacheLimitBytes(int bytes) => set(_kCacheLimit, '$bytes');
}
