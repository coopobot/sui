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

  const Notebook({
    required this.id,
    this.parentId,
    required this.name,
    this.sortOrder = 0,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.version = 0,
  });

  copyWith({
    String? parentId,
    String? name,
    int? sortOrder,
    bool? isDeleted,
    DateTime? updatedAt,
    int? version,
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
    );
  }
}