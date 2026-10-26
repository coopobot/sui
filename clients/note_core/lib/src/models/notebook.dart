import '../sync/entity_sync_state.dart';
/// 域模型：笔记本（支持树形嵌套）。
class Notebook {
  final String id;
  final String? parentId;
  final String name;
  final int sortOrder;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;

  /// M10-T29：是否为加密笔记本（其内笔记的标题 / 正文为**端到端密文**，服务端不可解密）。
  final bool encrypted;

  /// M10-T29：**非敏感**加密元数据（算法 / KDF 参数 / `salt` / `verifier` 的 JSON）；空串 = 未设置。
  final String cryptoMeta;

  /// M12（FR-53）：本端与云端的一致状态（**纯本地记账**：不进同步净荷、服务端不存储）。
  final EntitySyncState syncState;

  /// M12：最近一次同步失败原因（`syncState == EntitySyncState.failed` 时有意义）。
  final String syncError;

  /// M12：最近一次同步失败时间。
  final DateTime? syncErrorAt;

  const Notebook({
    required this.id,
    this.parentId,
    required this.name,
    this.sortOrder = 0,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
    this.encrypted = false,
    this.cryptoMeta = '',
    this.syncState = EntitySyncState.pending,
    this.syncError = '',
    this.syncErrorAt,
  });

  copyWith({
    String? parentId,
    String? name,
    int? sortOrder,
    bool? isDeleted,
    DateTime? updatedAt,
    int? version,
    bool? encrypted,
    String? cryptoMeta,
    EntitySyncState? syncState,
    String? syncError,
    DateTime? syncErrorAt,
  }) {
    return Notebook(
      id: id,
      parentId: parentId ?? this.parentId,
      name: name ?? this.name,
      sortOrder: sortOrder ?? this.sortOrder,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      version: version ?? this.version,
      encrypted: encrypted ?? this.encrypted,
      cryptoMeta: cryptoMeta ?? this.cryptoMeta,
      syncState: syncState ?? this.syncState,
      syncError: syncError ?? this.syncError,
      syncErrorAt: syncErrorAt ?? this.syncErrorAt,
    );
  }
}