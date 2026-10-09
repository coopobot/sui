import '../sync/entity_sync_state.dart';
/// 域模型：笔记。与数据库表 [Notes] 解耦，仓储负责映射。
class Note {
  final String id;
  final String? notebookId;
  final String title;
  final String contentMarkdown;
  final bool pinned;
  final bool archived;
  final bool isDeleted;
  final int revisionCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;
  final int version;
  final String sourceDevice;

  /// M10-T29：镜像所属笔记本的加密状态；为真时 [title] / [contentMarkdown] 是**密文**。
  final bool encrypted;


  /// M12（FR-53）：本端与云端的一致状态（**纯本地记账**：不进同步净荷、服务端不存储）。
  final EntitySyncState syncState;

  /// M12：最近一次同步失败原因（`syncState == EntitySyncState.failed` 时有意义）。
  final String syncError;

  /// M12：最近一次同步失败时间。
  final DateTime? syncErrorAt;

  /// M10-T29：**运行时标记（不落库）**——该笔记属于加密笔记本且当前**未解锁**，或密文损坏。
  /// 为真时 [title] 是占位文案、[contentMarkdown] 为空；UI 据此禁止进入编辑、排除搜索与预览。
  final bool locked;

  const Note({
    required this.id,
    this.notebookId,
    this.title = '',
    this.contentMarkdown = '',
    this.pinned = false,
    this.archived = false,
    this.isDeleted = false,
    this.revisionCount = 0,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
    this.version = 0,
    this.sourceDevice = '',
    this.encrypted = false,
    this.locked = false,
    this.syncState = EntitySyncState.pending,
    this.syncError = '',
    this.syncErrorAt,
  });

  Note copyWith({
    String? id,
    Object? notebookId = _unset,
    String? title,
    String? contentMarkdown,
    bool? pinned,
    bool? archived,
    bool? isDeleted,
    int? revisionCount,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? deletedAt = _unset,
    int? version,
    String? sourceDevice,
    bool? encrypted,
    bool? locked,
    EntitySyncState? syncState,
    String? syncError,
    DateTime? syncErrorAt,
  }) {
    return Note(
      id: id ?? this.id,
      notebookId: notebookId == _unset ? this.notebookId : notebookId as String?,
      title: title ?? this.title,
      contentMarkdown: contentMarkdown ?? this.contentMarkdown,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      isDeleted: isDeleted ?? this.isDeleted,
      revisionCount: revisionCount ?? this.revisionCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt == _unset ? this.deletedAt : deletedAt as DateTime?,
      version: version ?? this.version,
      sourceDevice: sourceDevice ?? this.sourceDevice,
      encrypted: encrypted ?? this.encrypted,
      locked: locked ?? this.locked,
      syncState: syncState ?? this.syncState,
      syncError: syncError ?? this.syncError,
      syncErrorAt: syncErrorAt ?? this.syncErrorAt,
    );
  }

  static const Object _unset = Object();
}

/// 变化摘要：用于展示最近修改（列表摘要）。
class NoteSummary {
  final Note note;
  final List<String> tags;

  const NoteSummary({required this.note, this.tags = const []});
}