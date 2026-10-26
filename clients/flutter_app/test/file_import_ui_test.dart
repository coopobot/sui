/// M13（FR-60 / FR-61 / FR-62）**客户端入口与报告**门禁（ui-spec §23）。
///
/// 覆盖：AC-233（全端入口可达且同源 / 菜单加速键）、AC-234（选择文件夹入口的平台门控）、
/// AC-235（目标笔记本只读呈现）、AC-240（加密未解锁笔记本拒绝导入的界面侧）、
/// AC-254（报告四类计数与明细）、AC-256（导入不改变当前编辑状态）。
///
/// **纪律**：
/// - 全程**禁用 `pumpAndSettle()`**（30s 周期同步器会让它永不返回，`Agents.md` §5.2），
///   改用有界 `pump`；
/// - `debugDefaultTargetPlatformOverride` 必须在**用例体结束前**复位——框架的
///   「foundation debug 变量已变更」不变量检查发生在 `addTearDown` **之前**；
/// - 加密笔记本的密钥派生（Argon2id）走真实异步 → 必须放在 `tester.runAsync` 内推进。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/import_picker.dart';
// 平台层的相对资源解析只在原生侧存在（Web 端没有文件系统），故直接引 io 实现。
// **带前缀**：分析器把上面的条件导出解析为 Web 分支（`dart.library.io` 视为假），
// 不加前缀会与 barrel 的同名符号冲突（`importFolderPickSupported` 等）。
import 'package:sui_flutter_app/src/platform/import_picker_io.dart' as io;
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/app_menu_bar.dart';
import 'package:sui_flutter_app/src/ui/desktop_commands.dart';
import 'package:sui_flutter_app/src/ui/import_dialog.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步器（Agents.md §5.2）。
Future<void> _settle(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 建一个可导入的控制器：内存库 + 临时数据目录（BlobStore 需要真实目录）。
Future<AppController> _controller(WidgetTester tester) async {
  final db = AppDatabase.memory();
  final dir = Directory.systemTemp.createTempSync('sui-m13-import').path;
  addTearDown(() => db.close());
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'm13-import-test'),
    database: db,
    dataDir: dir,
  );
  await controller.bootstrap();
  return controller;
}

/// 在指定画布尺寸下渲染真实 [NoteShell]。
Future<AppController> _pumpShell(WidgetTester tester, Size size) async {
  final controller = await _controller(tester);
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

/// 桌面外壳用例包装：设置平台覆盖 → 渲染 → 执行用例体 → **用例体结束前**复位覆盖。
Future<void> _desktopTest(
  WidgetTester tester,
  Future<void> Function(AppController controller) body, {
  Size size = const Size(1400, 900),
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    final controller = await _pumpShell(tester, size);
    await body(controller);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

ImportSourceFile _source(String name, String text) => ImportSourceFile(
      name: name,
      bytes: Uint8List.fromList(utf8.encode(text)),
    );

/// 按住 Ctrl+Shift 再敲某个键（`SingleActivator` 要求按下瞬间修饰键已生效）。
Future<void> _pressCtrlShift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  // 纯 Dart 用例（非 `testWidgets`）：这里做**真实文件 IO**，而 widget 测试的假时钟
  // 不会推进真实 IO 的 Future（会挂住）——`storage_settings_test.dart` 头部同源纪律。
  test('AC-245 平台层：相对资源解析的候选回退与越界拒绝', () async {
    // 造一个贴近印象笔记「导出为多个网页」的目录：
    //   <root>/note.html ＋ <root>/note files/image.png（另加一份 note.resources/b.pdf）
    final root = Directory.systemTemp.createTempSync('sui-m13-res');
    addTearDown(() => root.deleteSync(recursive: true));
    final html = File(p.join(root.path, 'note.html'))..writeAsStringSync('<html/>');
    final filesDir = Directory(p.join(root.path, 'note files'))..createSync();
    final img = File(p.join(filesDir.path, 'image.png'))
      ..writeAsBytesSync(const [1, 2, 3, 4]);
    final resDir = Directory(p.join(root.path, 'note.resources'))..createSync();
    final pdf = File(p.join(resDir.path, 'doc.pdf'))..writeAsBytesSync(const [9]);
    // 目录之外的同名文件：**不得**被读到（防 `..` 逃逸）。
    final outside = File(p.join(root.parent.path, 'secret.png'))
      ..writeAsBytesSync(const [7, 7, 7]);

    // ① 相对路径（含反斜杠，印象笔记实测形态）→ 落到资源目录。
    expect(
      await io.resolveImportResource(html.path, r'note files\image.png'),
      img.readAsBytesSync(),
    );
    // ② `.resources` 兼容命名 + 只给 basename 时按候选回退。
    expect(
      await io.resolveImportResource(html.path, 'doc.pdf'),
      pdf.readAsBytesSync(),
    );
    // ③ 越出 HTML 所在目录 → 拒绝（不读目录外文件）。
    expect(
      await io.resolveImportResource(
          html.path, '../${p.basename(outside.path)}'),
      isNull,
    );
    // ④ 取不到 → null（由 note_core 走「未本地化资源」降级）。
    expect(await io.resolveImportResource(html.path, 'missing.png'), isNull);
    // ⑤ 带 scheme / data: 的引用不在这里处理（远端图片不出网）。
    expect(
        await io.resolveImportResource(html.path, 'https://a/b.png'), isNull);
    expect(
        await io.resolveImportResource(
            html.path, 'data:image/png;base64,AA=='),
        isNull);
  });

  testWidgets('AC-233 命令注册表：导入命令存在且菜单/加速键同源', (tester) async {
    final controller = await _controller(tester);
    final command = desktopCommands[DesktopCommandId.importFiles];
    expect(command, isNotNull, reason: '命令必须登记在唯一来源 desktopCommands 里');
    expect(command!.label, '导入文件…');
    expect(command.shortcutLabel, 'Ctrl+Shift+I');
    expect(command.activator, isA<SingleActivator>());
    // 无选中笔记本时导入到「未分组」是允许的 → 恒可用。
    expect(command.isEnabled(controller), isTrue);
  });

  testWidgets('AC-233 / AC-235 桌面端：「文件 → 导入文件…」打开同一个对话框', (tester) async {
    await _desktopTest(tester, (controller) async {
      await controller.createNote(title: '既有笔记');
      await _settle(tester);
      final selected = controller.selectedNoteId;
      expect(selected, isNotNull);

      // 桌面外壳渲染的是应用菜单栏。
      expect(find.byType(AppMenuBar), findsOneWidget);
      await tester.tap(find.text('文件'));
      await _settle(tester);
      expect(find.text('导入文件…'), findsOneWidget);

      await tester.tap(find.text('导入文件…'));
      await _settle(tester);

      // 对话框：目标笔记本**只读**呈现 + 格式说明；未选中笔记本时给出提示与「未分组」。
      expect(find.text('导入文件'), findsOneWidget);
      expect(find.text('导入到：未分组'), findsOneWidget);
      expect(find.text('如需导入到某个笔记本，请先在左栏选中它'), findsOneWidget);
      expect(find.textContaining('支持 .md / .markdown / .txt'), findsOneWidget);
      // 全端都有「选择文件…」；文件夹入口按平台门控（测试跑在原生 VM 上 → 可见，AC-234）。
      expect(find.text('选择文件…'), findsOneWidget);
      if (importFolderPickSupported) {
        expect(find.text('选择文件夹…'), findsOneWidget);
      }

      // AC-256：打开对话框**不改变**当前选中笔记。
      expect(controller.selectedNoteId, selected);

      await tester.tap(find.text('取消'));
      await _settle(tester);
      expect(find.text('导入到：未分组'), findsNothing);
      expect(controller.selectedNoteId, selected);
    });
  });

  testWidgets('AC-233 桌面端：Ctrl+Shift+I 走同一命令打开对话框', (tester) async {
    await _desktopTest(tester, (controller) async {
      await _pressCtrlShift(tester, LogicalKeyboardKey.keyI);
      await _settle(tester);

      expect(find.text('导入文件'), findsOneWidget);
      expect(find.text('选择文件…'), findsOneWidget);
    });
  });

  testWidgets('AC-233 窄屏 / 移动端：「更多 → 导入文件…」可达', (tester) async {
    await _pumpShell(tester, const Size(400, 800));
    expect(find.byType(AppMenuBar), findsNothing);

    await tester.tap(find.byTooltip('更多'));
    await _settle(tester);
    // 导入入口排在「使用文档」之前（ui-spec §23.1）。
    expect(find.text('导入文件…'), findsOneWidget);
    expect(find.text('使用文档'), findsOneWidget);

    await tester.tap(find.text('导入文件…'));
    await _settle(tester);
    expect(find.text('导入文件'), findsOneWidget);
  });

  testWidgets('AC-240 加密且未解锁的目标笔记本：拒绝并提示，不打开对话框', (tester) async {
    await _desktopTest(tester, (controller) async {
      // 建一个加密笔记本并**回锁**，再把它选为目标。
      // Argon2id 派生走真实异步 → 用 `runAsync` 推进，否则会卡在假时钟里。
      String? nbId;
      await tester.runAsync(() async {
        final nb = await controller.repository.createNotebook(name: '机密');
        await controller.repository.setNotebookEncrypted(nb.id, 'pw-123456');
        controller.repository.lockNotebook(nb.id);
        nbId = nb.id;
      });
      controller.selectNotebook(nbId);
      await controller.refreshNotebooks();
      await _settle(tester);

      expect(await controller.importTargetBlockReason(), isNotNull);
      expect(controller.importTargetLabel, '机密');

      await tester.tap(find.text('文件'));
      await _settle(tester);
      await tester.tap(find.text('导入文件…'));
      await _settle(tester);

      // 拒绝口径：给提示、**不进入**导入对话框（连选择器都不打开）。
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('解锁'), findsWidgets);
      expect(find.text('选择文件…'), findsNothing);
    });
  });

  testWidgets('AC-254 报告：四类计数分列 + 逐项明细（可复制）', (tester) async {
    final controller = await _pumpShell(tester, const Size(1400, 900));
    await controller.createNote(title: '既有笔记');
    final selected = controller.selectedNoteId;

    final report = await controller.importSourceFiles([
      _source('a.md', '# 我的标题\n\n正文'),
      // 同批内内容重复 → 只导入第一篇，第二篇计「跳过（重复）」（AC-252）。
      _source('a-copy.md', '# 我的标题\n\n正文'),
      // 不支持的扩展名 → 跳过（AC-236）。
      _source('bad.docx', 'ignored'),
    ]);

    expect(report.successCount, 1);
    expect(report.skippedCount, 2);
    expect(report.failedCount, 0);
    // AC-256：导入不改变当前选中笔记。
    expect(controller.selectedNoteId, selected);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () =>
                      showImportReportDialog(context, controller, report),
                  child: const Text('看报告'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('看报告'));
    await _settle(tester);

    expect(find.text('导入完成'), findsOneWidget);
    expect(find.textContaining('成功 1 · 跳过 2 · 失败 0'), findsOneWidget);
    expect(find.text('复制报告'), findsOneWidget);
    expect(find.textContaining('我的标题'), findsWidgets);
    expect(find.textContaining('bad.docx'), findsWidgets);
  });

  // 纯 Dart 用例（真实文件 IO，不用 `testWidgets`——假时钟不推进 IO）。
  test('AC-234 收集规则：递归收集受支持文件、跳过导出资源目录与隐藏目录', () async {
    final root = Directory.systemTemp.createTempSync('sui-m13-collect');
    addTearDown(() => root.deleteSync(recursive: true));
    void write(String rel, String body) {
      final f = File(p.join(root.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(body);
    }

    write('a.html', '<html/>');
    write('a_files/image.png', 'x');
    // 印象笔记导出的资源目录里会夹带旁挂文本（实测 `org.txt`）→ 不得当成笔记（v0.13.1 修复）
    write('a_files/org.txt', 'sidecar');
    write('sub/b.md', '# b');
    write('.hidden/c.md', '# c');
    // 没有同名 `foo.html` 的 `foo_files` 目录：**不跳**（不误伤用户自己的笔记目录）
    write('foo_files/keep.txt', 'keep');

    final names = (await io.collectImportSourceFiles(root.path))
        .map((f) => f.name)
        .toList()
      ..sort();
    expect(names, ['a.html', 'b.md', 'keep.txt']);
  });
}
