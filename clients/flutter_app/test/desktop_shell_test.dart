/// M7-T11 桌面壳层 widget 测试（desktop-shell.md §9）。
///
/// 覆盖 FR-40 面板折叠（AC-111~AC-116）与 FR-41 自绘应用菜单栏（AC-117~AC-123）。
///
/// **纪律**：全程**禁用 `pumpAndSettle()`**，改用有界 `pump`（Agents.md §5.2）——
/// 连接服务端后 `AppController` 会挂 30s 周期同步器，`pumpAndSettle()` 把假时钟推过
/// 30s 后会切到 `SyncState.syncing`，顶栏渲染出**不定长** `CircularProgressIndicator`
/// （永远在排帧）→ 永不返回、静默卡到框架级超时。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/app_menu_bar.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_list.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/notebook_tree.dart';

/// 桌面外壳用例：临时把平台覆盖为桌面，并在**用例体内**复位。
///
/// 复位必须落在体内：`_verifyInvariants()`（断言 foundation 调试变量已复位）在**用例体
/// 结束后、`tearDown` 之前**执行（`flutter_test/src/binding.dart:1974`），
/// 放到 `tearDown` 里必然触发「The value of a foundation debug variable was changed by the test.」。
void _desktopTest(
  String description,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步器（Agents.md §5.2）。
Future<void> _settle(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 16),
  int frames = 30,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 让真实异步（drift 落库等）跑完再回一帧。
///
/// widget 测试的时钟是假的，`await` 到的库调用需要借 `runAsync` 落到真实事件循环。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
}

/// 构建外壳并返回已 `bootstrap()` 的 controller。
Future<AppController> _pumpShell(
  WidgetTester tester,
  AppDatabase db, {
  Size size = const Size(1200, 800),
}) async {
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'm7t11-test'),
    database: db,
  );
  await controller.bootstrap();

  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: const MaterialApp(home: NoteShell()),
    ),
  );
  await _settle(tester);
  return controller;
}

/// 打开顶层菜单：点标签文本 + 有界 pump（沿用 Flutter SDK 自身 menu 测试惯用法）。
Future<void> _openMenu(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 关闭已展开的菜单（Esc → DismissIntent）。
Future<void> _closeMenu(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

/// 菜单项定位：用 `widgetWithText` 精确到菜单项，避开侧栏同名文案
/// （如侧栏也有「新建笔记」「归档」「回收站」）。
Finder _menuItem(String label) => find.widgetWithText(MenuItemButton, label);

/// 读取菜单项可用性——`MenuItemButton.enabled` 即 `onPressed != null`（SDK 定义）。
bool _enabled(WidgetTester tester, String label) =>
    tester.widget<MenuItemButton>(_menuItem(label)).enabled;

void main() {
  // ---------------------------------------------------------------- FR-40

  group('FR-40 面板折叠', () {
    _desktopTest('折叠四态渲染：两栏独立折叠、编辑区常驻、无悬空分隔线（AC-111 / AC-116）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final controller = await _pumpShell(tester, db);

      // ① 两栏均展开：三栏并排，两处分隔线。
      expect(find.byType(NotebookTree), findsOneWidget);
      expect(find.byType(NoteList), findsOneWidget);
      expect(find.byType(NoteEditor), findsOneWidget);
      expect(find.byType(VerticalDivider), findsNWidgets(2));

      // ② 仅折叠左栏：分隔线与左栏同生共死。
      await controller.setLeftPanelCollapsed(true);
      await tester.pump();
      expect(find.byType(NotebookTree), findsNothing);
      expect(find.byType(NoteList), findsOneWidget);
      expect(find.byType(NoteEditor), findsOneWidget);
      expect(find.byType(VerticalDivider), findsNWidgets(1));

      // ③ 仅折叠中栏（左栏恢复）。
      await controller.setLeftPanelCollapsed(false);
      await controller.setNoteListCollapsed(true);
      await tester.pump();
      expect(find.byType(NotebookTree), findsOneWidget);
      expect(find.byType(NoteList), findsNothing);
      expect(find.byType(NoteEditor), findsOneWidget);
      expect(find.byType(VerticalDivider), findsNWidgets(1));

      // ④ 两栏均折叠：编辑区常驻，无悬空分隔线。
      await controller.setLeftPanelCollapsed(true);
      await tester.pump();
      expect(find.byType(NotebookTree), findsNothing);
      expect(find.byType(NoteList), findsNothing);
      expect(find.byType(NoteEditor), findsOneWidget);
      expect(find.byType(VerticalDivider), findsNothing);
    });

    _desktopTest('折叠不改上下文：选中与查询词原样恢复，搜索框文本同步（AC-112）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final controller = await _pumpShell(tester, db);

      await controller.createNotebook('工作');
      final notebookId = controller.notebooks.single.id;
      controller.selectNotebook(notebookId);
      await controller.createNote();
      final noteId = controller.selectedNoteId!;
      controller.search('会议');
      await _flush(tester);

      expect(controller.selectedNotebookId, notebookId);
      expect(controller.selectedNoteId, noteId);
      expect(controller.query, '会议');

      // 折叠是纯呈现：不得清空选中与查询词。
      await controller.setLeftPanelCollapsed(true);
      await controller.setNoteListCollapsed(true);
      await tester.pump();
      expect(controller.selectedNotebookId, notebookId);
      expect(controller.selectedNoteId, noteId);
      expect(controller.query, '会议');

      // 重新展开：搜索框文本随 `query` 复原（避免「框空但结果已筛」）。
      await controller.setNoteListCollapsed(false);
      await _flush(tester);
      expect(controller.query, '会议');
      final searchField = tester.widget<TextField>(
        find.descendant(of: find.byType(NoteList), matching: find.byType(TextField)),
      );
      expect(searchField.controller!.text, '会议');
    });

    _desktopTest('状态持久化：折叠态与编辑模式写入 settings，重建后恢复（AC-113）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);

      final first = AppController(
        repository: NoteRepository(db, deviceId: 'm7t11-test'),
        database: db,
      );
      await first.bootstrap();
      await first.setLeftPanelCollapsed(true);
      await first.setNoteListCollapsed(true);
      await first.setEditorMode(EditorMode.source);

      // 用同一内存库重建 controller：偏好应原样恢复（读同一 settings 表）。
      final second = AppController(
        repository: NoteRepository(db, deviceId: 'm7t11-test'),
        database: db,
      );
      await second.bootstrap();
      expect(second.leftPanelCollapsed, isTrue);
      expect(second.noteListCollapsed, isTrue);
      expect(second.editorMode, EditorMode.source);

      // UI 侧同证：恢复的折叠态直接落到首帧渲染。
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: second,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      await _settle(tester);
      expect(find.byType(NotebookTree), findsNothing);
      expect(find.byType(NoteList), findsNothing);
      expect(find.byType(NoteEditor), findsOneWidget);
    });

    _desktopTest('恢复入口常驻：折叠后顶栏切换控件仍可见可点并恢复（AC-114）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final controller = await _pumpShell(tester, db);

      // 展开态：提示为「折叠左侧栏」。
      expect(find.byTooltip('折叠左侧栏'), findsOneWidget);

      await controller.setLeftPanelCollapsed(true);
      await tester.pump();
      expect(find.byType(NotebookTree), findsNothing);
      // 恢复入口在顶栏（不在被折叠的栏内），提示翻转为「展开左侧栏」。
      expect(find.byTooltip('展开左侧栏'), findsOneWidget);

      await tester.tap(find.byTooltip('展开左侧栏'));
      await _flush(tester);
      expect(controller.leftPanelCollapsed, isFalse);
      expect(find.byType(NotebookTree), findsOneWidget);
    });

    _desktopTest('导航入口可达：左栏折叠时经菜单新建笔记本；「查找」自动展开中栏（AC-115 / AC-120）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final controller = await _pumpShell(tester, db);

      // 左栏折叠：栏内「新建笔记本」按钮不可达。
      await controller.setLeftPanelCollapsed(true);
      await tester.pump();
      expect(find.byType(NotebookTree), findsNothing);

      // 「文件 → 新建笔记本」仍可用（BR-40.5）。
      await _openMenu(tester, '文件');
      expect(_enabled(tester, '新建笔记本'), isTrue);
      await tester.tap(_menuItem('新建笔记本'));
      await _flush(tester);

      // 弹出命名对话框并创建。
      final dialogField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(dialogField, findsOneWidget);
      await tester.enterText(dialogField, '灵感');
      await tester.pump();
      await tester.tap(find.text('确定'));
      await _flush(tester);
      expect(controller.notebooks.map((n) => n.name), contains('灵感'));

      // 「查找」：中栏折叠时先自动展开，再聚焦其搜索框（§4.3）。
      await controller.setNoteListCollapsed(true);
      await tester.pump();
      expect(find.byType(NoteList), findsNothing);

      await _openMenu(tester, '编辑');
      await tester.tap(_menuItem('查找'));
      await _flush(tester);
      await tester.pump();
      await tester.pump();

      expect(controller.noteListCollapsed, isFalse);
      expect(find.byType(NoteList), findsOneWidget);
      final searchField = tester.widget<TextField>(
        find.descendant(of: find.byType(NoteList), matching: find.byType(TextField)),
      );
      expect(searchField.focusNode?.hasFocus, isTrue,
          reason: '「查找」应聚焦笔记列表搜索框（§4.3）');
    });

    _desktopTest('顶栏切换控件真实点击：折叠左栏 / 笔记列表并可原路恢复（AC-113 / AC-114）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final controller = await _pumpShell(tester, db);

      // ① 点击顶栏「折叠左侧栏」——走 `IconButton.onPressed` 的真实交互路径
      //   （此前用例只直调 controller，掩盖了「点了没反应」类故障，M7-T12 复盘）。
      expect(find.byTooltip('折叠左侧栏'), findsOneWidget);
      await tester.tap(find.byTooltip('折叠左侧栏'));
      await _flush(tester);
      expect(controller.leftPanelCollapsed, isTrue);
      expect(find.byType(NotebookTree), findsNothing);
      expect(find.byType(VerticalDivider), findsOneWidget);

      // ② 同一控件提示翻转为「展开左侧栏」，再点即恢复。
      await tester.tap(find.byTooltip('展开左侧栏'));
      await _flush(tester);
      expect(controller.leftPanelCollapsed, isFalse);
      expect(find.byType(NotebookTree), findsOneWidget);
      expect(find.byType(VerticalDivider), findsNWidgets(2));

      // ③ 中栏同理：真实点击折叠 / 恢复。
      await tester.tap(find.byTooltip('折叠笔记列表'));
      await _flush(tester);
      expect(controller.noteListCollapsed, isTrue);
      expect(find.byType(NoteList), findsNothing);

      await tester.tap(find.byTooltip('展开笔记列表'));
      await _flush(tester);
      expect(controller.noteListCollapsed, isFalse);
      expect(find.byType(NoteList), findsOneWidget);
    });

    _desktopTest('视图菜单勾选项与顶栏按钮同源：经菜单折叠 / 展开左栏（AC-118 / AC-120）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final controller = await _pumpShell(tester, db);

      // 视图菜单里的「切换左侧栏」承载同一命令（BR-41.2 等价聚合）。
      await _openMenu(tester, '视图');
      expect(_enabled(tester, '切换左侧栏'), isTrue);
      expect(find.text('✓'), findsWidgets, reason: '展开态应显示勾号');

      await tester.tap(_menuItem('切换左侧栏'));
      await _flush(tester);
      expect(controller.leftPanelCollapsed, isTrue);
      expect(find.byType(NotebookTree), findsNothing);

      // 再次经菜单切回：勾号消失、左栏回归。
      await _openMenu(tester, '视图');
      await tester.tap(_menuItem('切换左侧栏'));
      await _flush(tester);
      expect(controller.leftPanelCollapsed, isFalse);
      expect(find.byType(NotebookTree), findsOneWidget);
    });

    _desktopTest('落盘失败不阻断界面刷新：写库异常时折叠仍生效（M7-T12 回归）',
        (tester) async {
      final db = AppDatabase.memory();
      final controller = await _pumpShell(tester, db);
      // 模拟「本机偏好写库失败」（磁盘满 / 数据库被占用 / 沙箱拦截等）：
      // 关闭底层数据库，后续 `SettingsStore.set` 必抛。
      await db.close();
      addTearDown(() async {
        try {
          await db.close();
        } catch (_) {/* 已关闭，忽略 */}
      });

      // 不得抛出：写库失败只记录日志（`_persistPref` 兜底）。
      await controller.setLeftPanelCollapsed(true);
      await tester.pump();
      expect(controller.leftPanelCollapsed, isTrue,
          reason: '内存态应已更新，不因落盘失败而回退');
      expect(find.byType(NotebookTree), findsNothing,
          reason: '界面应随内存态刷新，而非停留在旧状态（M7-T12 缺陷）');

      // 中栏同型路径一并覆盖。
      await controller.setNoteListCollapsed(true);
      await tester.pump();
      expect(controller.noteListCollapsed, isTrue);
      expect(find.byType(NoteList), findsNothing);
    });
  });

  // ---------------------------------------------------------------- FR-41

  group('FR-41 应用菜单栏', () {
    _desktopTest('菜单栏呈现与降级：宽屏桌面出四菜单，窄屏 / 非桌面不出（AC-117 / AC-122）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      await _pumpShell(tester, db);

      // 宽屏桌面：菜单栏 / 折叠切换 / 标题齐备，且顺序为「菜单栏 → 切换 → 标题」（BR-41.5）。
      expect(find.byType(AppMenuBar), findsOneWidget);
      expect(find.byType(PanelToggles), findsOneWidget);
      for (final label in const ['文件', '编辑', '视图', '帮助']) {
        expect(find.text(label), findsOneWidget);
      }
      final menuX = tester.getTopLeft(find.byType(AppMenuBar)).dx;
      final toggleX = tester.getTopLeft(find.byType(PanelToggles)).dx;
      final titleX = tester.getTopLeft(find.text('随手记 Sui')).dx;
      expect(menuX, lessThan(toggleX));
      expect(toggleX, lessThan(titleX));

      // 非桌面平台（宽屏但仍降级）：不出菜单栏与切换控件（AC-122）。
      // 平台门控在 `LayoutBuilder` 回调内读取（note_shell.dart:20–31），只改覆盖值
      // 不会触发重建，须伴随一次约束变化（尺寸变更）才会重跑该回调。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      await _settle(tester);
      expect(find.byType(AppMenuBar), findsNothing);
      expect(find.byType(PanelToggles), findsNothing);
      // 宽屏三栏骨架仍在（只是不含桌面外壳）。
      expect(find.byType(NotebookTree), findsOneWidget);
      expect(find.byType(NoteEditor), findsOneWidget);

      // 窄屏：改走抽屉 + 堆栈，不出菜单栏与切换控件（BR-40.6 / BR-41.7）。
      await tester.binding.setSurfaceSize(const Size(800, 600));
      await _settle(tester);
      expect(find.byType(AppMenuBar), findsNothing);
      expect(find.byType(PanelToggles), findsNothing);
      // 抽屉是窄屏的导航入口：关闭态不建子树，展开后笔记本树可达（AC-116）。
      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await _settle(tester, frames: 40);
      expect(find.byType(NoteTreeDrawer), findsOneWidget);
      expect(find.byType(NotebookTree), findsOneWidget);
    });

    _desktopTest('命令等价与置灰：未选笔记时导出置灰，选中后可用且与工具栏同源（AC-118 / AC-119）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      final controller = await _pumpShell(tester, db);

      // 未选笔记：作用于笔记的「导出笔记」置灰，纯本地命令可用。
      await _openMenu(tester, '文件');
      expect(_enabled(tester, '导出笔记'), isFalse);
      expect(_enabled(tester, '新建笔记'), isTrue);

      // 点「新建笔记」：建笔记并关闭菜单——菜单只是既有入口的**等价聚合**（BR-41.2）。
      await tester.tap(_menuItem('新建笔记'));
      await _flush(tester);
      expect(controller.selectedNoteId, isNotNull);
      expect(find.byType(NoteEditor), findsOneWidget);

      // 选中后：「导出笔记」解禁，执行体复用编辑区同名能力（走同一导出对话框）。
      await _openMenu(tester, '文件');
      expect(_enabled(tester, '导出笔记'), isTrue);
      await tester.tap(_menuItem('导出笔记'));
      await _flush(tester);
      expect(find.text('导出 Markdown'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await _flush(tester);
      expect(find.text('导出 Markdown'), findsNothing);

      // 「视图 → 源码模式」与编辑区 SegmentedButton 读写同一状态（同源同效）。
      await _openMenu(tester, '视图');
      await tester.tap(_menuItem('源码模式'));
      await _flush(tester);
      expect(controller.editorMode, EditorMode.source);
      expect(
        tester
            .widget<SegmentedButton<EditorMode>>(
              find.byType(SegmentedButton<EditorMode>),
            )
            .selected,
        {EditorMode.source},
      );
    });

    _desktopTest('快捷键提示：已有快捷键的命令显示提示文本（AC-121）', (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      await _pumpShell(tester, db);

      // 无快捷键的命令不显示提示文本（BR-41.6）。
      await _openMenu(tester, '文件');
      expect(tester.widget<MenuItemButton>(_menuItem('新建笔记')).trailingIcon, isNull);
      await _closeMenu(tester);

      // 「编辑」菜单提示 FR-30 定义的 6 个快捷键（BR-41.6 / AC-121）。
      await _openMenu(tester, '编辑');
      for (final shortcut in const [
        'Ctrl+Z',
        'Ctrl+Shift+Z',
        'Ctrl+X',
        'Ctrl+C',
        'Ctrl+V',
        'Ctrl+A',
      ]) {
        expect(find.text(shortcut), findsOneWidget, reason: '「编辑」菜单应提示 $shortcut');
      }
    });

    _desktopTest('既有能力不回归：同步图标 / 同步设置 / 新建笔记动作仍在且可点（AC-123）',
        (tester) async {
      final db = AppDatabase.memory();
      addTearDown(db.close);
      await _pumpShell(tester, db);

      // 顶栏既有动作原样保留（BR-41.5）。
      expect(find.byTooltip('未连接服务端 · 点击配置'), findsOneWidget);
      expect(find.byTooltip('同步设置'), findsOneWidget);
      expect(find.byTooltip('新建笔记'), findsOneWidget);

      // 「同步设置」仍可打开既有对话框。
      await tester.tap(find.byTooltip('同步设置'));
      await _flush(tester);
      expect(find.text('服务端地址'), findsOneWidget);
    });
  });
}
