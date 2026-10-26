/// M15 / FR-74 笔记属性面板测试（ui-spec §26.2 / BR-74.1\~74.5）。
///
/// 覆盖：字段渲染与顺序、只读（无任何输入控件）、空态、来源链接（空则整行不渲染 /
/// 白名单外不打开 / 打开失败提示）、加密未解锁不展示字数·字符数、
/// 桌面宽屏右栏「属性 ↔ 版本历史」二选一、窄屏整页推入、时间双格式（helper 纯函数）。
///
/// **纪律**：全程**禁用 `pumpAndSettle()`**（Agents.md §5.2），改用有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/url_opener.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_properties_panel.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/revision_panel.dart';
import 'package:sui_flutter_app/src/ui/time_format.dart';

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步器（Agents.md §5.2）。
Future<void> _settle(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 已 `bootstrap()` 的控制器；数据库与控制器在用例结束时一并释放。
Future<AppController> _buildController(String deviceId) async {
  final db = AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: deviceId),
    database: db,
  );
  addTearDown(() async {
    controller.dispose();
    await db.close();
  });
  await controller.bootstrap();
  return controller;
}

/// 把面板挂到一块**足够高**的画布上：11 行字段在 600px 默认高度下会被 `ListView`
/// 惰性裁剪成「不存在」，断言会误判。
Future<void> _pumpPanel(
  WidgetTester tester,
  AppController controller, {
  required String noteId,
  DateTime Function()? debugNow,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: MaterialApp(
        home: Scaffold(
          body: NotePropertiesPanel(noteId: noteId, debugNow: debugNow),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  // ------------------------------------------------------------ 时间双格式

  group('时间双格式 helper（FR-74 / ui-spec §26.2）', () {
    test('本地时间：`yyyy-MM-dd HH:mm`，可选到秒；按本地时区呈现', () {
      final t = DateTime(2026, 10, 15, 14, 3, 5);
      expect(formatLocalDateTime(t), '2026-10-15 14:03');
      expect(formatLocalDateTime(t, withSeconds: true), '2026-10-15 14:03:05');
      expect(formatLocalDate(t), '2026-10-15');
    });

    test('相对时间：刚刚 / 分钟 / 小时 / 天，超 7 天回落日期（now 可注入）', () {
      final now = DateTime(2026, 10, 15, 14, 3);
      expect(formatRelativeTime(now, now: now), '刚刚');
      expect(
        formatRelativeTime(now.subtract(const Duration(seconds: 30)), now: now),
        '刚刚',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(minutes: 5)), now: now),
        '5 分钟前',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(hours: 3)), now: now),
        '3 小时前',
      );
      expect(
        formatRelativeTime(now.subtract(const Duration(days: 2)), now: now),
        '2 天前',
      );
      // ≥ 7 天：相对形式会退化成一长串数字，故回落绝对日期。
      expect(
        formatRelativeTime(now.subtract(const Duration(days: 30)), now: now),
        formatLocalDate(now.subtract(const Duration(days: 30))),
      );
      // 未来时间（时钟偏差）按「刚刚」处理，不出现负数。
      expect(
        formatRelativeTime(now.add(const Duration(hours: 2)), now: now),
        '刚刚',
      );
    });
  });

  // ------------------------------------------------------------ 字段与只读

  testWidgets('字段齐全且只读：标题 / 笔记本路径 / 双格式时间 / 标签 / 修订 / 版本 / 设备 / 同步 / 字数',
      (tester) async {
    final controller = await _buildController('m15-props-fields');
    await controller.createNotebook('工作');
    final root = controller.notebooks.firstWhere((n) => n.name == '工作');
    await controller.createNotebook('项目A', parentId: root.id);
    final child = controller.notebooks.firstWhere((n) => n.name == '项目A');

    final t = DateTime(2026, 10, 15, 14, 3);
    final note = await controller.repository.createNote(
      notebookId: child.id,
      title: '属性面板样例',
      // 8 个字符（含换行），去空白后 7 个 → 「7 字 · 8 字符」。
      contentMarkdown: '你好世界\nabc',
      tags: const ['标签一', '标签二'],
      now: t,
      sourceDevice: 'device-x',
      sourceUrl: 'https://example.com/post',
    );
    await controller.refreshNotes();

    await _pumpPanel(
      tester,
      controller,
      noteId: note.id,
      debugNow: () => DateTime(2026, 10, 15, 17, 3),
    );

    // 只有**按 id 直取**才拿得到（中栏此时并未选中该笔记）。
    expect(controller.selectedNoteId, isNull);
    expect(find.text('属性面板样例'), findsOneWidget);
    // 所属笔记本：名称 + 祖先路径（` / ` 分隔）。
    expect(find.text('工作 / 项目A'), findsOneWidget);
    // 时间双格式：本地 + 相对**同处一行**；样例里创建时间与修改时间同值 → 两行。
    expect(find.text('2026-10-15 14:03（3 小时前）'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('sui-props-tags')), findsOneWidget);
    // 标签顺序由仓储给定（不承诺用户输入序），故按集合断言，只锁「都在」。
    final tagsText =
        tester.widget<Text>(find.byKey(const ValueKey('sui-props-tags'))).data!;
    expect(tagsText.split('、'), unorderedEquals(['标签一', '标签二']));
    expect(find.text('1'), findsOneWidget); // 修订次数（新建即有 1 条修订）
    expect(find.text('0（本地新建，尚未上行）'), findsOneWidget);
    expect(find.text('device-x'), findsOneWidget);
    // 同步状态取 `EntitySyncState.label`（**单一来源**）：本地新建尚未上行时的具体
    // 状态由 M12 的本地记账决定（新建即 `pending`，核对后可能为 `localOnly`），
    // 故这里断言「呈现的就是该实体的状态文案」，不硬编码具体某一态。
    expect(
      find.text(controller.noteById(note.id)!.syncState.label),
      findsOneWidget,
    );
    expect(find.text('7 字 · 8 字符'), findsOneWidget);

    // **只读**（BR-74.1）：面板内没有任何输入 / 编辑控件。
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.byType(EditableText), findsNothing);
    // 只读标识可见。
    expect(
      find.byKey(const ValueKey('sui-note-properties-readonly')),
      findsOneWidget,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('值可复制：行尾复制按钮写入剪贴板且不改正本', (tester) async {
    final controller = await _buildController('m15-props-copy');
    final note = await controller.repository.createNote(
      title: '可复制标题',
      contentMarkdown: '正文',
      now: DateTime(2026, 10, 15, 14, 3),
    );
    await controller.refreshNotes();

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await _pumpPanel(tester, controller, noteId: note.id);
    await tester.tap(find.byKey(const ValueKey('sui-props-title-copy')));
    await tester.pump();
    await tester.pump();

    expect(copied, '可复制标题');
    // 复制**不改正本**（BR-74.1）：笔记内容一字不变。
    final after = controller.noteById(note.id)!;
    expect(after.title, '可复制标题');
    expect(after.contentMarkdown, '正文');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('中栏筛选态下仍能按 id 直取展示（BR-74.3：不得用受筛选影响的结果集）',
      (tester) async {
    final controller = await _buildController('m15-props-filter');
    final note = await controller.repository.createNote(
      title: '被筛掉的笔记',
      contentMarkdown: '正文',
      now: DateTime(2026, 10, 15, 14, 3),
    );
    await controller.refreshNotes();

    // 中栏加一个**不匹配**的搜索词：该笔记随即不在当前结果集里。
    controller.search('完全不匹配的关键词');
    await controller.refreshNotes();
    expect(controller.notes.any((s) => s.note.id == note.id), isFalse);
    expect(controller.noteById(note.id), isNull);

    await _pumpPanel(tester, controller, noteId: note.id);
    await _settle(tester, frames: 8);

    // 面板照常显示（兜底按 id 直取），不因中栏筛选而空。
    expect(find.text('被筛掉的笔记'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sui-note-properties-empty')),
      findsNothing,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ------------------------------------------------------------ 来源链接

  testWidgets('来源链接为空 → 整行不渲染（不显示占位符）', (tester) async {
    final controller = await _buildController('m15-props-nolink');
    final note = await controller.repository.createNote(
      title: '非剪藏笔记',
      contentMarkdown: '正文',
      now: DateTime(2026, 10, 15, 14, 3),
    );
    await controller.refreshNotes();

    await _pumpPanel(tester, controller, noteId: note.id);

    expect(find.byKey(const ValueKey('sui-props-source-url')), findsNothing);
    expect(find.text('来源链接'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('来源链接（白名单内）可点击打开；打开失败只提示、不改正本', (tester) async {
    final controller = await _buildController('m15-props-link');
    final note = await controller.repository.createNote(
      title: '剪藏笔记',
      contentMarkdown: '正文',
      sourceUrl: 'https://example.com/post',
      now: DateTime(2026, 10, 15, 14, 3),
    );
    await controller.refreshNotes();

    final opened = <String>[];
    var ok = true;
    debugUrlOpenerOverride = (url) async {
      opened.add(url);
      return ok;
    };
    addTearDown(() => debugUrlOpenerOverride = null);

    await _pumpPanel(tester, controller, noteId: note.id);
    expect(find.byKey(const ValueKey('sui-props-source-url')), findsOneWidget);
    expect(find.text('https://example.com/post'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sui-props-source-url')));
    await tester.pump();
    await tester.pump();
    expect(opened, ['https://example.com/post']);

    // 打开失败（无可用浏览器 / 壳层不可用）→ 明确提示，正本不动（BR-70.4）。
    ok = false;
    await tester.tap(find.byKey(const ValueKey('sui-props-source-url')));
    await tester.pump();
    await tester.pump();
    expect(opened.length, 2);
    expect(find.textContaining('未能打开链接'), findsOneWidget);
    expect(controller.noteById(note.id)!.sourceUrl, 'https://example.com/post');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('来源链接协议不在白名单 → 行内呈现但不打开（BR-70.2）', (tester) async {
    final controller = await _buildController('m15-props-badscheme');
    final note = await controller.repository.createNote(
      title: '可疑来源',
      contentMarkdown: '正文',
      sourceUrl: 'javascript:alert(1)',
      now: DateTime(2026, 10, 15, 14, 3),
    );
    await controller.refreshNotes();

    final opened = <String>[];
    debugUrlOpenerOverride = (url) async {
      opened.add(url);
      return true;
    };
    addTearDown(() => debugUrlOpenerOverride = null);

    await _pumpPanel(tester, controller, noteId: note.id);
    expect(find.text('javascript:alert(1)'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sui-props-source-url')));
    await tester.pump();
    expect(opened, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ------------------------------------------------------------ 加密未解锁

  testWidgets('加密笔记本未解锁 → 不展示字数 / 字符数，只给遮罩文案（BR-74.4）', (tester) async {
    final controller = await _buildController('m15-props-locked');
    // `fromWire` + `encrypted: true`：模拟「已加密且当前未解锁」的存储形态——
    // 读取接缝（toDisplayNote）会返回占位并置 `locked = true`（无密钥可解）。
    final note = await controller.repository.createNote(
      title: '密文标题',
      contentMarkdown: '密文正文',
      fromWire: true,
      encrypted: true,
      now: DateTime(2026, 10, 15, 14, 3),
    );
    await controller.refreshNotes();
    expect(controller.noteById(note.id)!.locked, isTrue);

    await _pumpPanel(tester, controller, noteId: note.id);

    // 正文派生量：**位置给遮罩文案而非数字**。
    expect(find.byKey(const ValueKey('sui-props-stats')), findsNothing);
    expect(
      find.byKey(const ValueKey('sui-props-stats-locked')),
      findsOneWidget,
    );
    expect(find.text('内容已加密，解锁后可见'), findsOneWidget);
    // 非内容元数据照常展示（承 BR-51）。
    expect(find.text('字数 / 字符数'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.byKey(const ValueKey('sui-props-created')), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ------------------------------------------------------------ 空态

  testWidgets('目标笔记不存在 → 空态文案，不崩溃、不阻塞编辑（FR-74）', (tester) async {
    final controller = await _buildController('m15-props-empty');

    await _pumpPanel(tester, controller, noteId: 'note-not-exist');
    await _settle(tester, frames: 6);

    expect(
      find.byKey(const ValueKey('sui-note-properties-empty')),
      findsOneWidget,
    );
    expect(find.text('笔记不存在或尚未同步到本机'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  // ------------------------------------------------------------ 载体互斥

  testWidgets('桌面宽屏右栏：属性与版本历史二选一（BR-74.5）', (tester) async {
    final controller = await _buildController('m15-props-wide');
    // 尺寸取 1600×900：三栏 + 320px 右栏同时展开时，编辑区仍有 ~559px——
    // 1200×800 下右栏会把编辑区压到 275px，触发 `note_editor` **紧凑模式行**的
    // 13px 溢出（既有最小宽度问题，用既有「版本历史」右栏同样会触发，非本改动引入）；
    // 本用例要锁的是**互斥**语义，故取一个能容纳三栏 + 右栏的桌面宽度。
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await controller.createNote();
    final noteId = controller.selectedNoteId!;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: NoteShell()),
      ),
    );
    await _settle(tester);

    // 初始：两栏都不显示（同一槽位空闲）。
    expect(find.byType(NotePropertiesPanel), findsNothing);
    expect(find.byType(RevisionPanel), findsNothing);

    // 打开属性 → 只出现属性面板。
    controller.setPropertiesPanelVisible(true);
    await _settle(tester);
    expect(find.byType(NotePropertiesPanel), findsOneWidget);
    expect(find.byType(RevisionPanel), findsNothing);

    // 再开版本历史 → **不并列**：同一槽位仍只有属性面板（属性优先）。
    controller.setRevisionPanelVisible(true);
    await _settle(tester);
    expect(find.byType(NotePropertiesPanel), findsOneWidget);
    expect(find.byType(RevisionPanel), findsNothing);

    // 关掉属性 → 先前打开的历史面板露出来（两个入口互不影响可达性）。
    controller.setPropertiesPanelVisible(false);
    await _settle(tester);
    expect(find.byType(NotePropertiesPanel), findsNothing);
    expect(find.byType(RevisionPanel), findsOneWidget);
    expect(controller.selectedNoteId, noteId);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('窄屏整页推入：属性面板占满编辑页，返回键关闭后回到编辑页（FR-74）',
      (tester) async {
    final controller = await _buildController('m15-props-narrow');
    await tester.binding.setSurfaceSize(const Size(700, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await controller.createNote();
    final noteId = controller.selectedNoteId!;
    await controller.saveNote(noteId, title: '窄屏笔记', content: '正文');

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: NoteShell()),
      ),
    );
    await _settle(tester);

    controller.setPropertiesPanelVisible(true);
    await _settle(tester);

    // 整页推入：AppBar 标题为「属性」，正文位置是属性面板（不是编辑器）。
    expect(find.widgetWithText(AppBar, '属性'), findsOneWidget);
    expect(find.byType(NotePropertiesPanel), findsOneWidget);
    expect(find.byType(RevisionPanel), findsNothing);

    // 返回 → 关闭面板回编辑页（两级返回里的第一级）。
    await tester.tap(find.byType(BackButton));
    await _settle(tester);
    expect(controller.showPropertiesPanel, isFalse);
    expect(find.byType(NotePropertiesPanel), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
