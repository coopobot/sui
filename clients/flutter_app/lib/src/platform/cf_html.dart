import 'dart:convert';

/// 解析 Windows 剪贴板的 **CF_HTML（`HTML Format`）** 字节流，取出片段 HTML
/// （FR-71 / editor-formatting.md §17.2）。
///
/// CF_HTML 的结构是：ASCII 头部
/// （`Version` / `StartHTML` / `EndHTML` / `StartFragment` / `EndFragment` /
/// `StartSelection` / `EndSelection`）+ UTF-8 的 HTML 正文；**所有偏移都是从字节流
/// 起点算起的字节偏移**（不是字符偏移，故必须按 `List<int>` 切片再解码）。
///
/// 取片段的口径（与浏览器 / Office 一致）：
/// 1. `StartFragment` / `EndFragment` 齐备且合法 → 只取**片段**（用户真正选中的部分）；
/// 2. 否则退回 `StartHTML` / `EndHTML`；
/// 3. 头部缺失（部分应用直接往剪贴板写 HTML 片段）→ 整体按 UTF-8 解码。
///
/// 任何异常都返回 null（调用方回落纯文本），**绝不抛出**。
String? decodeCfHtml(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final head = _headText(bytes);
  final fragment = _slice(
    bytes,
    _offset(head, 'StartFragment'),
    _offset(head, 'EndFragment'),
  );
  if (fragment != null) return fragment;
  final whole = _slice(
    bytes,
    _offset(head, 'StartHTML'),
    _offset(head, 'EndHTML'),
  );
  if (whole != null) return whole;
  final decoded = utf8.decode(bytes, allowMalformed: true).trim();
  return decoded.isEmpty ? null : decoded;
}

/// 头部探测窗口：CF_HTML 头部只有几百字节，2 KiB 足够，且避免在大 HTML 上重复扫描。
const int _headProbe = 2048;

/// 头部一律按 ASCII（latin1）读：偏移量是数字，正文不必进来。
String _headText(List<int> bytes) {
  final end = bytes.length < _headProbe ? bytes.length : _headProbe;
  return latin1.decode(bytes.sublist(0, end), allowInvalid: true);
}

/// 读取头部字段 `key: <number>`；缺失 / 非法返回 null。
int? _offset(String head, String key) {
  final m = RegExp('$key\\s*:\\s*(\\d+)', caseSensitive: false).firstMatch(head);
  if (m == null) return null;
  final v = int.tryParse(m.group(1)!);
  return (v == null || v < 0) ? null : v;
}

/// 按**字节**区间切片并解码；区间非法（越界 / 倒序 / 空）返回 null。
String? _slice(List<int> bytes, int? start, int? end) {
  if (start == null || end == null) return null;
  if (start < 0 || start >= end || end > bytes.length) return null;
  final text = utf8.decode(bytes.sublist(start, end), allowMalformed: true).trim();
  return text.isEmpty ? null : text;
}
