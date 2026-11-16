import 'dart:io';

import 'package:flutter/services.dart';

import 'platform_seams.dart';

/// 自研平台通道（Windows / Android 原生实现的唯一入口，见 ADR-028）。
const MethodChannel _channel = MethodChannel('sui/platform');

/// 读剪贴板的**位图**（FR-123 / ADR-047）。
///
/// * **Windows**：通道 `sui/platform` 的 `clipboardImage` 回**可直接解码**的图片字节
///   （注册格式 `PNG` 优先；否则 `CF_DIB` 在原生侧补 `BITMAPFILEHEADER` 成 BMP）；
/// * **Android / iOS / macOS / Linux**：本轮未实现，恒 null（BR-123.2，登记为已知限制）。
///
/// 任何异常都吞掉并返回 null：粘贴链路必须**静默回落**，绝不能因为读不到位图而
/// 让整个粘贴抛异常（BR-123.2 / BR-71.6）。
Future<Uint8List?> readClipboardImage() async {
  // 测试接缝：注入后不再触碰原生通道（生产代码从不写入，见 platform_seams.dart）。
  final override = debugClipboardImageOverride;
  if (override != null) return override();
  if (!Platform.isWindows) return null;
  try {
    final bytes = await _channel.invokeMethod<Uint8List>('clipboardImage');
    if (bytes == null || bytes.isEmpty) return null;
    return bytes;
  } catch (_) {
    // 原生通道不可用 / 格式异常：静默回落。
    return null;
  }
}
