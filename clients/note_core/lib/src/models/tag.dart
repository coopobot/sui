import '../sync/entity_sync_state.dart';
/// 域模型：标签。
class Tag {
  final String id;
  final String name;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;

  /// M12（FR-53）：本端与云端的一致状态（**纯本地记账**：不进同步净荷、服务端不存储）。
  final EntitySyncState syncState;

  /// M12：最近一次同步失败原因（`syncState == EntitySyncState.failed` 时有意义）。
  final String syncError;

  /// M12：最近一次同步失败时间。
  final DateTime? syncErrorAt;

  const Tag({
    required this.id,
    required this.name,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.syncState = EntitySyncState.pending,
    this.syncError = '',
    this.syncErrorAt,
  });
}