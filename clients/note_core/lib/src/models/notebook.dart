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
    );
  }
}