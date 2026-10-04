import '../bootstrap.dart';

/// Web（无 `dart:io` 环境）不支持多窗口独立笔记窗口（详细设计 §6）。
///
/// 入口据此分流：`false` 时走既有 `runApp(SuiApp(...))` 单视图路径。
bool get supportsMultiWindow => false;

/// Web 兜底：多窗口入口不可用。
///
/// 正常路径不会走到（[supportsMultiWindow] 恒为 `false`）；保留同名同签名仅为
/// 条件导入两侧 API 一致，编译通过。
void runMultiWindowApp({required AppStorage storage}) {
  throw UnsupportedError('当前平台不支持多窗口（独立笔记窗口仅桌面端可用）');
}
