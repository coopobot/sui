/// 读剪贴板的 **HTML 表示**（FR-71 / ADR-028）。
///
/// Windows 读 CF_HTML（"HTML Format"）的原始字节、Android 读 `ClipData` 的 HTML 项；
/// 其余平台（macOS / Linux / Web）本轮未实现，恒返回 null，调用方回落
/// `Clipboard.getData(text/plain)`（BR-71.5：登记为已知限制，不算缺陷）。
///
/// 约定：本模块**只负责拿到原始文本/字节**，CF_HTML 的解析与 HTML→Markdown 转换
/// 一律放在 Dart 侧（[cf_html.dart] + `note_core` 的 DOM 转换器），便于单测。
library;

export 'clipboard_html_web.dart' if (dart.library.io) 'clipboard_html_io.dart';
export 'platform_seams.dart';
