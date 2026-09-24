/// 随手记 Sui — note_core
///
/// 多端共享的核心逻辑包。不依赖 Flutter，仅依赖 Dart SDK 与本地存储。
/// 提供：数据模型、本地库（drift/SQLite）、Blob 存储抽象、仓储服务、同步引擎。
library;

export 'src/blob/blob_store.dart';
export 'src/blob/cached_blob_store.dart';
export 'src/blob/local_blob_store.dart';
export 'src/blob/sqlite_blob_cache_meta.dart';
export 'src/models/attachment.dart';
export 'src/models/note.dart';
export 'src/models/notebook.dart';
export 'src/models/revision.dart';
export 'src/models/sync_config.dart';
export 'src/models/tag.dart';
export 'src/repository/note_repository.dart';
export 'src/repository/settings_store.dart';
export 'src/db/app_database.dart';
export 'src/util/ids.dart';
export 'src/sync/auth_client.dart';
export 'src/sync/sync_client.dart';
