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
}