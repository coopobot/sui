/// 域模型：修订记录（历史版本）。
class Revision {
  final String id;
  final String noteId;
  final int version;
  final String title;
  final String contentMarkdown;
  final String? diffDelta;
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
    this.sourceDevice = '',
    this.isConflict = false,
    required this.createdAt,
  });
}