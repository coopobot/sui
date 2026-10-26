import 'tag.dart';

/// 标签总览：标签 + 关联笔记数量（FR-22）。
///
/// 数量基于本机已落库的关联（`note_tags`），已软删除的笔记不计入（BR-22.1）。
class TagSummary {
  final Tag tag;
  final int noteCount;

  const TagSummary({required this.tag, required this.noteCount});

  String get name => tag.name;
}
