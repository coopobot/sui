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
  /// 受保护通道的服务端指纹（TOFU 信任根，M10-T27 / FR-50，auth.md §9.2）。
  static const _kChannelFingerprint = 'channel.fingerprint';
  static const _kCacheLimit = 'blob.cacheLimitBytes';
  /// M12（FR-55）：最近一次成功同步的**云端实例身份**（换库 / 重建判定依据）。
  static const _kInstanceId = 'sync.instanceId';
  /// M12：持久化拉取游标（已含 `−1s` 安全回退，见 sync-status.md §9）。
  static const _kLastPull = 'sync.lastPull';
  /// M12：最近一次「全部重新同步」完成时间。
  static const _kLastReconcileAt = 'sync.lastReconcileAt';

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

  /// M12：云端实例身份（未记录返回 null）。
  Future<String?> instanceId() async {
    final v = await get(_kInstanceId);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setInstanceId(String id) => set(_kInstanceId, id.trim());

  /// M12：持久化拉取游标（UTC；未记录返回 null）。
  Future<DateTime?> lastPull() async {
    final v = await get(_kLastPull);
    if (v == null || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toUtc();
  }

  Future<void> setLastPull(DateTime since) =>
      set(_kLastPull, since.toUtc().toIso8601String());

  /// M12：最近一次「全部重新同步」完成时间。
  Future<DateTime?> lastReconcileAt() async {
    final v = await get(_kLastReconcileAt);
    if (v == null || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toUtc();
  }

  Future<void> setLastReconcileAt(DateTime at) =>
      set(_kLastReconcileAt, at.toUtc().toIso8601String());

  /// 受保护通道的服务端指纹；未记录（首次连接）返回 null。
  ///
  /// 首次握手成功后记录；此后**不一致即阻断**（疑似中间人）——判定在 `SecureChannelClient`。
  Future<String?> channelFingerprint() async {
    final v = await get(_kChannelFingerprint);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setChannelFingerprint(String fingerprint) =>
      set(_kChannelFingerprint, fingerprint.trim());
}
