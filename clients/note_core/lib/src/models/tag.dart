/// 域模型：标签。
class Tag {
  final String id;
  final String name;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version;

  const Tag({
    required this.id,
    required this.name,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
  });
}