import 'dart:io';

import 'package:flutter/services.dart';

import 'cf_html.dart';
import 'platform_seams.dart';

/// 自研平台通道（Windows / Android 原生实现的唯一入口，见 ADR-028）。
const MethodChannel _channel = MethodChannel('sui/platform');

/// 读剪贴板的 **HTML 表示**（原始 HTML 文本）；无 HTML 表示 / 平台不支持时返回 null。
///
/// * **Windows**：通道回 CF_HTML 的**原始字节**（`HTML Format`），这里按
///   `StartFragment` / `EndFragment` 切片并解码（[decodeCfHtml]）；
/// * **Android**：通道回 `ClipData` 的 HTML 文本（`ClipData.Item.getHtmlText()`）；
/// * **iOS / macOS / Linux**：本轮未实现，恒 null（BR-71.5）。
///
/// 任何异常都吞掉并返回 null：粘贴链路必须**静默回落纯文本**，绝不能因为读不到
/// 富文本而让「粘贴无反应」（BR-71.6）。
Future<String?> readClipboardHtml() async {
  // 测试接缝：注入后不再触碰原生通道（生产代码从不写入，见 platform_seams.dart）。
  final override = debugClipboardHtmlOverride;
  if (override != null) return override();
  try {
    if (Platform.isWindows) {
      final bytes = await _channel.invokeMethod<Uint8List>('clipboardHtml');
      if (bytes == null || bytes.isEmpty) return null;
      return decodeCfHtml(bytes);
    }
    if (Platform.isAndroid) {
      final html = await _channel.invokeMethod<String>('clipboardHtml');
      if (html == null || html.trim().isEmpty) return null;
      return html;
    }
  } catch (_) {
    // 原生通道不可用 / 格式异常：回落纯文本。
  }
  return null;
}
