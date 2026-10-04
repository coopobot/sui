import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:multiview_desktop/multiview_desktop.dart';

import '../app.dart';
import '../bootstrap.dart';
import '../ui/note_window.dart';
import '../ui/note_window_manager.dart';

/// 当前平台是否支持多窗口独立笔记窗口（详细设计 §6）。
///
/// 与 `note_shell.dart` 的桌面判定同口径：非 Web 且为桌面三平台
/// （Windows / macOS / Linux）。移动端虽同样具备 `dart:io`，但不走多窗口。
bool get supportsMultiWindow {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

/// 主窗口在 `multiview_desktop` 中的**公开视图 id 恒为 `1`**（详细设计 §3.1 / §4.1）。
const int _mainPublicViewId = 1;

/// 把库的**公开视图 id** 折算为注册表口径的**窗口句柄**（详细设计 §4.1 / §5.1）：
/// 主窗口统一折算为 [kMainViewKey]，独立窗口沿用其视图 id。
Object _handleForPublicId(int publicId) =>
    publicId == _mainPublicViewId ? kMainViewKey : publicId;

/// 窗口生命周期观察者：把 `multiview_desktop` 的原生回调转发到平台无关的
/// [WindowEventHub]（详细设计 §4 / §5.1 / §9.1）。
///
/// 观察者随 `MultiAppConfig.observers` **先于** `globalScope` 构造，此刻
/// `AppController` 尚未创建，故此处**只依赖枢纽**、不直接持有控制器；控制器在创建时
/// 经 [WindowEventHub.bind] 订阅（见 `ui/note_window_manager.dart`）。
class SuiWindowObserver extends WindowObserver {
  SuiWindowObserver(this._hub);

  final WindowEventHub _hub;

  /// 新窗口打开：登记活动窗口。
  ///
  /// 主窗口**不触发**本回调（主窗口由控制器预置，详细设计 §4.1）；此处仍做 id 折算，
  /// 以防库实现变化。
  @override
  void onWindowOpened(int viewId, {int? parentViewId}) {
    _hub.emitWindowOpened(_handleForPublicId(viewId));
  }

  /// 窗口关闭：**含主窗口**（主窗口关闭即「最后一个窗口」，触发退出，§7）。
  @override
  void onWindowClosed(int viewId) {
    _hub.emitWindowClosed(_handleForPublicId(viewId));
  }

  /// 原生窗口事件：仅关心 `focus`，用于把命令派发目标切到该窗口（§5.1）。
  @override
  void onWindowEvent(int viewId, String eventName) {
    if (eventName == 'focus') {
      _hub.emitViewFocused(_handleForPublicId(viewId));
    }
  }
}

/// 桌面实现：以 `multiview_desktop` 的 `openWindow` / `MultiViewDesktop` 承载
/// [NoteWindowManager] 接缝（详细设计 §4 / §7 / §9.1）。
///
/// 句柄即 [openWindow] 返回的**公开视图 id**（`int`），同时也是 `SuiNoteWindow.viewId`
/// 与 `NoteEditor.viewKey`——三者同值，故注册表、命令派发与窗口操作共用同一句柄。
class MultiViewNoteWindowManager implements NoteWindowManager {
  /// 独立笔记窗口的初始内容尺寸（逻辑像素）。
  static const Size _initialSize = Size(760, 640);

  /// 创建承载 [noteId] 的**新建**独立窗口，返回其公开视图 id 作为句柄（§4.3）。
  ///
  /// `openWindow` 的 `childBuilder` 收到的 `publicId` 与返回值**同值**（库在
  /// `addWindow` 内把同一公开 id 既传入 `child` 又作为结果返回），故可直接交给
  /// [SuiNoteWindow] 用作 `viewId`。去重与聚焦由 [AppController] 注册表负责，此处
  /// **只管新建**。
  @override
  Future<Object?> openNoteWindow(String noteId) {
    return openWindow(
      (context, publicId) => SuiNoteWindow(noteId: noteId, viewId: publicId),
      options: const WindowOptions(
        title: '随手记 Sui',
        size: _initialSize,
        minimumSize: Size(420, 360),
      ),
    );
  }

  /// 置前并聚焦；若最小化则先还原（BR-43.2）。
  @override
  void focusNoteWindow(Object handle) {
    if (handle is! int) return;
    final window = MultiViewDesktop.fromId(handle);
    if (window.isMinimized()) window.restore();
    window.focus();
  }

  /// 软关闭句柄对应窗口（BR-43.4）。
  @override
  Future<void> closeNoteWindow(Object handle) async {
    if (handle is! int) return;
    await MultiViewDesktop.fromId(handle).closeWindow();
  }

  /// 句柄指向的窗口是否仍有效（BR-43.6 异常自愈）。
  ///
  /// `allWindowViewIds` 是**次级窗口**（不含主窗口）公开 id 的快照。
  @override
  bool isNoteWindowValid(Object handle) {
    if (handle is! int) return false;
    return MultiViewDesktop.allWindowViewIds.contains(handle);
  }

  /// 关闭全部独立笔记窗口（「文件 → 退出应用」第 3 步，详细设计 §7）。
  ///
  /// 先取快照再逐个关闭：关闭过程会改动活动窗口集合，直接迭代实时列表会漏关。
  @override
  Future<void> closeAllNoteWindows() async {
    for (final viewId in List<int>.of(MultiViewDesktop.allWindowViewIds)) {
      await MultiViewDesktop.fromId(viewId).closeWindow();
    }
  }
}

/// 桌面端多窗口入口：以 `runMultiApp` 取代 `runApp`（详细设计 §3.4）。
///
/// - `home` 返回**主窗口完整入口** [SuiMainWindow]（含 `MaterialApp`）；库会把主视图
///   包进 `MainAppShellCapture`、其余窗口包进 `SharedEntryApp` 复现同一外观，
///   故独立窗口内容**不得**再套第二层 `MaterialApp`。
/// - `globalScope` 挂 [SharedAppScope]，让主窗口与独立窗口共享**同一** `AppController`
///   （单引擎多视图，ADR-012 §3.1）；同时注入独立窗口管理器与事件枢纽。
/// - `config.observers` 注册 [SuiWindowObserver]，驱动窗口注册表与「无窗口即退出」
///   （详细设计 §4 / §7）。
void runMultiWindowApp({required AppStorage storage}) {
  final hub = WindowEventHub();
  final windowManager = MultiViewNoteWindowManager();
  runMultiApp(
    home: (ctx, viewId) => const SuiMainWindow(),
    globalScope: (child) => SharedAppScope(
      storage: storage,
      windowManager: windowManager,
      windowEventHub: hub,
      child: child,
    ),
    config: MultiAppConfig(
      generalParams: const MultiPlatformParams(closeMode: CloseMode.softCascade),
      observers: [SuiWindowObserver(hub)],
    ),
  );
}
