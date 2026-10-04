import 'package:flutter/foundation.dart';

/// 是否处于**桌面三平台**（Windows / macOS / Linux）且非 Web。
///
/// 桌面端壳层（菜单栏、命令入口、独立笔记窗口入口）与平台降级的**唯一判定口径**
/// （详细设计 §6，沿用 M7 口径）。用 [defaultTargetPlatform] 而非 `dart:io` 的
/// `Platform`：Web 上后者不可用，且能避免条件导入；[kIsWeb] 先行兜底，避免 Web
/// 被误判为桌面。
bool get isDesktopPlatform {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}
