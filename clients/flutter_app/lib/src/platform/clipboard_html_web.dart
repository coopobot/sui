import 'platform_seams.dart';

/// Web 端的剪贴板 HTML 读取（FR-71 / BR-71.5）。
///
/// 本轮**不做** Web 实现：浏览器剪贴板事件由 Flutter Web 的文本编辑层接管，
/// 应用侧拿不到 `ClipboardEvent.clipboardData` 的 `text/html`（要改写 Web 端输入管线，
/// 风险与验证成本都超出本次补丁范围）。恒返回 null，粘贴回落纯文本。
///
/// （`Clipboard.getData` 在 Web 端同样只给 `text/plain`——浏览器权限模型所限。）
Future<String?> readClipboardHtml() async {
  // 测试接缝：注入后不再返回恒定 null（见 platform_seams.dart）。
  final override = debugClipboardHtmlOverride;
  if (override != null) return override();
  return null;
}
