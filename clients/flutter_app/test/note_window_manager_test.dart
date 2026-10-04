/// M8-T12 独立笔记窗口接缝单测（详细设计 [`multi-window.md`] §9.1）。
///
/// 真实多窗口只在桌面端可跑，且牵动 OS 窗口与 `multiview_desktop`（`dart:io` / `dart:ffi`）。
/// 故按设计把窗口管理抽为**可替换接缝**（[NoteWindowManager] + [WindowEventHub] 内存实现），
/// 让注册表逻辑（打开去重聚焦 / 关闭释放 / 占用态 / 异常自愈 / 平台降级 / 命令归属）在**纯
/// Dart 单测**里被完整驱动。
///
/// **纪律**：绝不关闭主窗口——`_activeWindows` 预置 `kMainViewKey`，只要不 `emitWindowClosed`
/// 主窗口键，则「集合清空 → `exit(0)`」分支永不触发，测试进程安全（详细设计 §7）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/desktop_commands.dart';
import 'package:sui_flutter_app/src/ui/note_window_manager.dart';

/// 内存窗口管理器（可替换接缝，§9.1）：记录调用并模拟句柄有效性。
class _FakeWindowManager implements NoteWindowManager {
  /// 新建调用次数（每次返回一个新的 int 句柄）。
  int openCount = 0;

  /// 每次新建时的 `noteId`（校验去重：已打开的笔记不应再触发新建）。
  final List<String> openedNoteIds = [];

  /// `focusNoteWindow` 收到的句柄序列。
  final List<Object> focused = [];

  /// `closeNoteWindow` 收到的句柄序列。
  final List<Object> closed = [];

  /// `closeAllNoteWindows` 调用次数。
  int closeAllCount = 0;

  /// 被标为**失效**的句柄（模拟系统关窗但回调未及，AC-133 异常自愈）。
  final Set<Object> invalid = {};

  @override
  Future<Object?> openNoteWindow(String noteId) async {
    openCount++;
    openedNoteIds.add(noteId);
    return openCount; // 句柄取递增 int，便于与 `_nextHandle` 区分
  }

  @override
  void focusNoteWindow(Object handle) => focused.add(handle);

  @override
  Future<void> closeNoteWindow(Object handle) async => closed.add(handle);

  @override
  bool isNoteWindowValid(Object handle) => !invalid.contains(handle);

  @override
  Future<void> closeAllNoteWindows() async => closeAllCount++;
}

/// 最小编辑器命令桥假实现（仅供命令归属用例）。
class _FakeEditorTarget implements EditorCommandTarget {
  @override
  bool get canUndo => false;
  @override
  bool get canRedo => false;
  @override
  void undo() {}
  @override
  void redo() {}
  @override
  void cut() {}
  @override
  void copy() {}
  @override
  void paste() {}
  @override
  void selectAll() {}
  @override
  void exportNote() {}
  @override
  Future<void> flushPendingEdits() async {}
}

/// 构建已 `bootstrap()` 的控制器；`manager` / `hub` 为 null 时即平台降级路径。
Future<AppController> _buildController({
  NoteWindowManager? manager,
  WindowEventHub? hub,
}) async {
  final db = AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'm8t12-test'),
    database: db,
    windowManager: manager,
    windowEventHub: hub,
  );
  addTearDown(controller.dispose);
  await controller.bootstrap();
  return controller;
}

void main() {
  group('M8 独立笔记窗口注册表（§4 / §9.1）', () {
    test('打开未打开笔记 → 新建窗口 + 主窗口选中不变（AC-124 / AC-125）', () async {
      final hub = WindowEventHub();
      final mgr = _FakeWindowManager();
      final controller = await _buildController(manager: mgr, hub: hub);

      await controller.createNote();
      final noteId = controller.selectedNoteId!;
      expect(controller.isNoteOpen(noteId), isFalse);

      await controller.openNoteInWindow(noteId);

      // 新建一次，句柄入注册表。
      expect(mgr.openCount, 1);
      expect(mgr.openedNoteIds, [noteId]);
      expect(controller.isNoteOpen(noteId), isTrue);
      final handle = controller.openNoteHandles[noteId];
      expect(handle, isNotNull);

      // 主窗口照常保留该笔记的编辑面（BR-42.2 / §5.3）：选中**不变**，两窗口两面并行。
      expect(controller.selectedNoteId, noteId);

      // 活动视图切到新窗口句柄，命令派发到该窗口（§5.1）。
      expect(controller.activeViewKey, handle);
    });

    test('重复打开＝聚焦，不新开（AC-129 / AC-130）', () async {
      final hub = WindowEventHub();
      final mgr = _FakeWindowManager();
      final controller = await _buildController(manager: mgr, hub: hub);

      await controller.createNote();
      final noteId = controller.selectedNoteId!;

      await controller.openNoteInWindow(noteId);
      final handle = controller.openNoteHandles[noteId]!;
      await controller.openNoteInWindow(noteId);

      expect(mgr.openCount, 1); // 未新开
      expect(mgr.focused, [handle]); // 聚焦既有窗口（BR-43.1 / BR-43.2）
    });

    test('关闭释放占用 + 可再次打开（AC-131）', () async {
      final hub = WindowEventHub();
      final mgr = _FakeWindowManager();
      final controller = await _buildController(manager: mgr, hub: hub);

      await controller.createNote();
      final noteId = controller.selectedNoteId!;
      await controller.openNoteInWindow(noteId);
      final handle = controller.openNoteHandles[noteId]!;

      // 模拟真实关闭回调（SuiWindowObserver 转发）。
      hub.emitWindowClosed(handle);

      expect(controller.isNoteOpen(noteId), isFalse); // 占用释放
      expect(controller.openNoteHandles, isEmpty);
      expect(controller.activeViewKey, kMainViewKey); // 活动视图回落主窗口

      // 可再次打开：得到新句柄。
      await controller.openNoteInWindow(noteId);
      expect(mgr.openCount, 2);
      expect(controller.openNoteHandles[noteId], isNot(handle));
    });

    test('占用态信号随打开 / 关闭自增，驱动列表标识（AC-132）', () async {
      final hub = WindowEventHub();
      final mgr = _FakeWindowManager();
      final controller = await _buildController(manager: mgr, hub: hub);

      await controller.createNote();
      final noteId = controller.selectedNoteId!;

      var changes = 0;
      void listener() => changes++;
      controller.openNotesChanged.addListener(listener);
      addTearDown(() => controller.openNotesChanged.removeListener(listener));

      await controller.openNoteInWindow(noteId);
      expect(changes, 1);
      expect(controller.isNoteOpen(noteId), isTrue);

      hub.emitWindowClosed(controller.openNoteHandles[noteId]!);
      expect(changes, 2);
      expect(controller.isNoteOpen(noteId), isFalse);
    });

    test('句柄失效 → 自愈清理并当「未打开」处理（AC-133）', () async {
      final hub = WindowEventHub();
      final mgr = _FakeWindowManager();
      final controller = await _buildController(manager: mgr, hub: hub);

      await controller.createNote();
      final noteId = controller.selectedNoteId!;
      await controller.openNoteInWindow(noteId);
      final stale = controller.openNoteHandles[noteId]!;

      mgr.invalid.add(stale); // 系统已关但回调未及
      await controller.openNoteInWindow(noteId);

      expect(mgr.openCount, 2); // 清理失效句柄后新建
      expect(controller.openNoteHandles[noteId], isNot(stale));
      expect(controller.isNoteOpen(noteId), isTrue);
    });

    test('未注入窗口管理器 → 降级为主窗口选中，不开窗（AC-128）', () async {
      final controller = await _buildController(); // manager / hub 均 null

      await controller.createNote();
      final noteId = controller.selectedNoteId!;
      controller.selectNote(null); // 先清空选中，验证降级确实「选中该笔记」
      expect(controller.selectedNoteId, isNull);

      await controller.openNoteInWindow(noteId);

      expect(controller.selectedNoteId, noteId); // 主窗口内选中
      expect(controller.openNoteHandles, isEmpty); // 未开任何窗口
      expect(controller.activeViewKey, kMainViewKey);
    });

    test('窗口开 / 关维护活动窗口计数（§7）', () async {
      final hub = WindowEventHub();
      final mgr = _FakeWindowManager();
      final controller = await _buildController(manager: mgr, hub: hub);

      await controller.createNote();
      final noteId = controller.selectedNoteId!;
      await controller.openNoteInWindow(noteId);
      final handle = controller.openNoteHandles[noteId]!;

      expect(controller.activeWindowCount, 1); // 仅主窗口
      hub.emitWindowOpened(handle); // 观察者转发（次级窗口）
      expect(controller.activeWindowCount, 2);
      hub.emitWindowClosed(handle);
      expect(controller.activeWindowCount, 1);
    });

    test('命令按活动视图归属到各自 target；目标缺失即可用作置灰依据（AC-126 / AC-134）', () async {
      final hub = WindowEventHub();
      final mgr = _FakeWindowManager();
      final controller = await _buildController(manager: mgr, hub: hub);

      await controller.createNote();
      final noteId = controller.selectedNoteId!;
      await controller.openNoteInWindow(noteId);
      final winHandle = controller.openNoteHandles[noteId]!;

      final mainTarget = _FakeEditorTarget();
      final winTarget = _FakeEditorTarget();
      controller.registerEditorTarget(kMainViewKey, mainTarget);
      controller.registerEditorTarget(winHandle, winTarget);

      controller.setActiveViewKey(kMainViewKey);
      expect(controller.targetFor(controller.activeViewKey), same(mainTarget));

      controller.setActiveViewKey(winHandle);
      expect(controller.targetFor(controller.activeViewKey), same(winTarget));

      // 未挂载编辑器的视图 → null（命令置灰）。
      expect(controller.targetFor('ghost'), isNull);
    });
  });
}
