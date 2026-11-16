import 'dart:typed_data';

import 'platform_seams.dart';

/// Web 端的剪贴板位图读取（FR-123 / BR-123.2）。
///
/// 本轮**不做** Web 实现：需要 Async Clipboard API（`navigator.clipboard.read()`）
/// 的权限与用户手势配合，且要改 Flutter Web 的粘贴事件管线——风险与验证成本
/// 都超出本次补丁范围。恒返回 null，粘贴回落文本（登记为已知限制）。
Future<Uint8List?> readClipboardImage() async {
  // 测试接缝：注入后不再返回恒定 null（见 platform_seams.dart）。
  final override = debugClipboardImageOverride;
  if (override != null) return override();
  return null;
}
