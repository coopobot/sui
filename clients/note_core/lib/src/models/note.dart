import '../sync/entity_sync_state.dart';

/// 网页剪藏默认标签名（M16 / FR-86 / BR-86.1）。
///
/// 服务端剪藏成功时自动挂上；客户端「收件箱」把它作为 `sourceUrl` / `clip:` 之外的
/// **兜底判据**（BR-86.2）。三端共用同一常量，避免各自写字符串。
const String kWebClipTagName = '网页剪藏';

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

  /// `v0.13.2`：剪藏来源标记（服务端 `notes.source_url` 的镜像，**只下行不上行**）。
  final String sourceUrl;

  /// 该笔记是否由网页剪藏产生——「收件箱」判据（BR-05.1 / BR-05.4）。
  ///
  /// 主判据是不可变的 [sourceUrl]；`clip:` 前缀仅作**兜底**（空 URL 剪藏、
  /// 老服务端不下发该字段）。**不得**只看 [sourceDevice]：它的语义是「最近一次
  /// 修改的来源设备」，本机 push 会改写它，只按它判定会让剪藏笔记永久退出收件箱。
  bool get isClip => sourceUrl.isNotEmpty || sourceDevice.startsWith('clip:');

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
    this.sourceUrl = '',
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
    String? sourceUrl,
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
      sourceUrl: sourceUrl ?? this.sourceUrl,
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