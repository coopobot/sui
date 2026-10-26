import 'dart:io';

import 'package:flutter/services.dart';

import 'platform_seams.dart';
import 'url_schemes.dart';

/// 自研平台通道（Windows / Android 原生实现的唯一入口，见 ADR-028）。
const MethodChannel _channel = MethodChannel('sui/platform');

/// 用系统默认浏览器打开 [url]；成功返回 true（见 [url_opener.dart] 的口径说明）。
Future<bool> openExternalUrl(String url) async {
  final target = url.trim();
  if (!isOpenableUrl(target)) return false;
  // 测试接缝：注入后不再触碰系统壳层 / 原生通道。
  final override = debugUrlOpenerOverride;
  if (override != null) return override(target);
  try {
    if (Platform.isAndroid) {
      // Android 无 POSIX 壳层：走自研原生通道（`ACTION_VIEW`）。
      final ok = await _channel.invokeMethod<bool>('openUrl', {'url': target});
      return ok ?? false;
    }
    if (Platform.isWindows) {
      // `start` 是 cmd 内建命令：首参固定为窗口标题（空串占位），随后才是目标地址。
      await Process.start('cmd', ['/c', 'start', '', target]);
      return true;
    }
    if (Platform.isMacOS) {
      return (await Process.run('open', [target])).exitCode == 0;
    }
    if (Platform.isLinux) {
      return (await Process.run('xdg-open', [target])).exitCode == 0;
    }
  } catch (_) {
    return false;
  }
  return false;
}
