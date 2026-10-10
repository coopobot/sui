/// 本地存储位置的**平台无关**常量（M12 修订 / FR-58）。
///
/// 单独成文件是为了让「常量」与「平台实现」分离：
/// `storage_location.dart` 在导出平台实现的同时**无条件导出本文件**，
/// 避免条件导入解析差异导致调用方看不到这些名字。
library;

/// 引导指针文件名（位于**应用支持根**，不随数据目录迁移）。
const String kStoragePointerFileName = 'storage.json';

/// 本地库文件名（drift，见 note_core `connection_io.dart`）。
const String kDatabaseFileName = 'sui.sqlite';

/// 附件缓存目录名（内容寻址：`blobs/<sha[:2]>/<sha>`）。
const String kBlobsDirName = 'blobs';

/// 迁移校验比对的关键表（BR-58.4）。
const List<String> kVerifiedTables = <String>[
  'notes',
  'notebooks',
  'tags',
  'revisions',
  'settings',
];
