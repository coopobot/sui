/// 桌面「退出应用」的平台条件导入（详细设计 §7）。
///
/// - 原生：`exit(0)` 结束进程。
/// - Web：空实现——Web 下菜单栏本就不呈现，此分支仅作编译兜底。
///
/// 与既有 `data_dir.dart` 同一模式：把 `dart:io` 隔离在条件导入之后，
/// 避免 Web 构建因直接引用 `dart:io` 而失败。
library;

export 'app_lifecycle_web.dart' if (dart.library.io) 'app_lifecycle_io.dart';
