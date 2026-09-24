/// 数据目录解析的平台条件导入。
///
/// - 原生：`path_provider` 的应用支持目录（各端规范位置）。
/// - Web：返回 null（持久化位置由浏览器存储决定，无文件系统路径）。
library;

export 'data_dir_web.dart' if (dart.library.io) 'data_dir_io.dart';