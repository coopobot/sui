/// 用**系统默认浏览器**打开外部网址（FR-70 / ADR-028）。
///
/// 平台差异全部收敛在本模块：
/// * Windows / macOS / Linux —— 复用既有系统壳层（`cmd /c start` / `open` / `xdg-open`），
///   与附件「用外部应用打开」同一套做法；
/// * Android —— 自研原生通道 `sui/platform` 的 `openUrl`（`ACTION_VIEW` Intent），
///   不经第三方插件（BR-70.3 零新增依赖）；
/// * Web —— `window.open`；
/// * iOS —— 本轮未实现（无原生通道），恒返回 false（BR-71.5 同类已知限制）。
///
/// 返回 `false` 表示**未能打开**（协议不在白名单 / 无可用浏览器 / 壳层不可用），
/// 由 UI 层据此提示；本模块**绝不抛出**。
library;

export 'platform_seams.dart';
export 'url_schemes.dart';
export 'url_opener_web.dart' if (dart.library.io) 'url_opener_io.dart';
