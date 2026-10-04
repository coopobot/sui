/// 桌面端多窗口（单引擎多视图）的平台条件导入（详细设计 §3.4 / §6）。
///
/// - 原生（含桌面 / 移动）：`multi_window_io.dart`，接入 `multiview_desktop`；
/// - Web：`multi_window_stub.dart`，仅作编译兜底。
///
/// 与既有 `app_lifecycle.dart` / `data_dir.dart` 同一模式：把平台相关依赖隔离在
/// 条件导入之后，避免 Web 构建因引用桌面专用库而失败。
/// 运行期再按 `defaultTargetPlatform` 判定是否真正启用多窗口（移动端降级单视图）。
library;

export 'multi_window_stub.dart' if (dart.library.io) 'multi_window_io.dart';
