/// 域模型：修订记录（历史版本）。
class Revision {
  final String id;
  final String noteId;
  final int version;
  final String title;
  final String contentMarkdown;
  final String? diffDelta;
  /// 已同步的服务端版本号；null = 未同步草稿（sync-protocol §8.2/§9.3）。
  final int? serverVersion;
  final String sourceDevice;
  final bool isConflict;
  final DateTime createdAt;

  const Revision({
    required this.id,
    required this.noteId,
    required this.version,
    this.title = '',
    required this.contentMarkdown,
    this.diffDelta,
    this.serverVersion,
    this.sourceDevice = '',
    this.isConflict = false,
    required this.createdAt,
  });
}