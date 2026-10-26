import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'ui/appearance/app_palette.dart';
import 'bootstrap.dart';
import 'ui/app_controller.dart';
import 'ui/note_shell.dart';
import 'ui/note_window_manager.dart';

// 主题构建已迁至 `appearance/app_palette.dart`（M14 / FR-64 / FR-67）：
// 亮 / 暗两套 + 中性角色覆盖 + 外观扩展 `SuiAppearance`（承载中性色板与笔记正文字体）。

/// 共享应用作用域：创建**唯一**的 [AppController] 并注入 Provider。
///
/// 桌面端多窗口下，各窗口（主窗口 / 独立笔记窗口）共享**同一** `AppController`
/// 与**同一份**本地库（M8 · ADR-012 §3.1）：主窗口与独立窗口都从各自 `context`
/// 读到同一对象。挂载在 `runMultiApp` 的 `globalScope`（包裹全部视图），
/// 见 `platform/multi_window_io.dart`。
class SharedAppScope extends StatelessWidget {
  const SharedAppScope({
    super.key,
    required this.storage,
    required this.child,
    this.windowManager,
    this.windowEventHub,
  });

  final AppStorage storage;
  final Widget child;

  /// 桌面多窗口的独立笔记窗口管理器；Web / 移动端 / 单测为 `null`（优雅降级）。
  final NoteWindowManager? windowManager;

  /// 窗口事件枢纽；桌面端由 `runMultiWindowApp` 注入，其余为 `null`。
  final WindowEventHub? windowEventHub;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppController(
        repository: storage.repository,
        database: storage.db,
        dataDir: storage.dataDir,
        storageResolution: storage.resolution,
        windowManager: windowManager,
        windowEventHub: windowEventHub,
      )..bootstrap(),
      child: child,
    );
  }
}

/// 主窗口入口：完整应用入口（`MaterialApp` + 三栏骨架）。
///
/// 桌面端作为 `runMultiApp` 的 `home`（主视图）。库会把它包进 `MainAppShellCapture`、
/// 把其余窗口包进 `SharedEntryApp` 复现同一外观——故**独立窗口内容不得再套第二层
/// `MaterialApp`**（详细设计 §3.4）。
class SuiMainWindow extends StatelessWidget {
  const SuiMainWindow({super.key});

  @override
  Widget build(BuildContext context) {
    // M14（FR-64 / FR-65）：主题三态与两项字体来自 `AppController`（**本机偏好**）。
    // 桌面多窗口下所有窗口共享同一控制器，故外观改动**跨窗口一致**（AC-274 / AC-291）。
    final controller = context.watch<AppController>();
    return MaterialApp(
      title: '随手记 Sui',
      theme: buildSuiTheme(
        brightness: Brightness.light,
        uiFontFamily: controller.uiFontFamily,
        bodyFontFamily: controller.bodyFontFamily,
      ),
      darkTheme: buildSuiTheme(
        brightness: Brightness.dark,
        uiFontFamily: controller.uiFontFamily,
        bodyFontFamily: controller.bodyFontFamily,
      ),
      // 「跟随系统」交给框架：`ThemeMode.system` 已监听平台亮度变化（BR-64.2）。
      themeMode: controller.themeMode,
      home: const NoteShell(),
    );
  }
}

/// 非桌面端单视图入口（自带共享作用域）。
///
/// 桌面端多窗口路径用 [SuiMainWindow] + [SharedAppScope]（见 `main.dart` 分流）。
class SuiApp extends StatelessWidget {
  const SuiApp({super.key, required this.storage});

  final AppStorage storage;

  @override
  Widget build(BuildContext context) {
    return SharedAppScope(
      storage: storage,
      child: const SuiMainWindow(),
    );
  }
}
