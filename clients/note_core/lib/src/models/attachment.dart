/// 域模型：附件元数据。字节存 BlobStore，这里只存引用 + hash。
class Attachment {
  final String id;
  final String? noteId;
  final String filename;
  final String mimeKind;
  final int byteSize;
  final String sha256;
  final String storageRef;
  final String? thumbnailRef;
  final int embeddedPos;
  final bool isDeleted;
  final DateTime createdAt;

  const Attachment({
    required this.id,
    this.noteId,
    required this.filename,
    required this.mimeKind,
    this.byteSize = 0,
    required this.sha256,
    required this.storageRef,
    this.thumbnailRef,
    this.embeddedPos = 0,
    this.isDeleted = false,
    required this.createdAt,
  });

  /// 同步协议载荷（不含 noteId —— 归属由所属笔记决定）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'filename': filename,
        'mimeKind': mimeKind,
        'byteSize': byteSize,
        'sha256': sha256,
        'storageRef': storageRef,
        'thumbnailRef': thumbnailRef,
        'embeddedPos': embeddedPos,
        'isDeleted': isDeleted,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  /// 从服务端载荷还原；[noteId] 由调用方按所属笔记补齐。
  factory Attachment.fromJson(Map<String, dynamic> json, {String? noteId}) =>
      Attachment(
        id: json['id'] as String,
        noteId: noteId,
        filename: (json['filename'] as String?) ?? '',
        mimeKind: (json['mimeKind'] as String?) ?? '',
        byteSize: (json['byteSize'] as int?) ?? 0,
        sha256: (json['sha256'] as String?) ?? '',
        storageRef: (json['storageRef'] as String?) ?? '',
        thumbnailRef: json['thumbnailRef'] as String?,
        embeddedPos: (json['embeddedPos'] as int?) ?? 0,
        isDeleted: (json['isDeleted'] as bool?) ?? false,
        createdAt:
            DateTime.tryParse((json['createdAt'] as String?) ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
}

/// 待写入的附件映射（M13 / FR-60.6「每篇导入是一个库事务」）。
///
/// 只带**建立映射所需的最小信息**：附件字节由调用方**先**经 BlobStore 落盘
/// （内容寻址天然幂等），本对象用于在同一事务里插入 `attachments` 行并做 refcount 记账。
class PendingAttachment {
  const PendingAttachment({
    required this.filename,
    required this.sha256,
    required this.byteSize,
    required this.mimeKind,
  });

  final String filename;
  final String sha256;
  final int byteSize;
  final String mimeKind;
}