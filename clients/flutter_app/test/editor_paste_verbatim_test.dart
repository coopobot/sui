/// 补丁 `v0.22.1`：**普通粘贴按 Markdown 原文插入**（FR-122 / BR-122.1\~122.7 / AC-705\~AC-712）。
///
/// 背景：Sui 编辑器复制只写 `text/plain`（没有 HTML 表示），普通粘贴回落纯文本时被
/// `EditorFormat.escapePlainText` 逐字符转义 → `[]` 变成 `\[\]`、链接 / 图片 / 勾选框结构丢失。
///
/// 覆盖的冻结口径：
/// * **普通粘贴**（`Ctrl+V`，无 HTML）→ 纯文本只归换行后**原样插入**，不前置反斜杠；
/// * **两态同源**：格式态与源码态普通粘贴的结果逐字节相同（源码态零加工）；
/// * **`Ctrl+Shift+V`** 仍是**唯一**的字面转义入口（`[x](y)` → `\[x\]\(y\)`）；
/// * **只归换行**（`\r\n` / `\r` → `\n`），不折叠空行、不补结尾换行（BR-122.2）；
/// * 粘贴仍是**一次**可撤销编辑（BR-122.4）。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（Agents.md §5.2：30s 周期同步 + 不定长进度条会静默
/// 卡到 10 分钟超时），一律有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

// ---------------------------------------------------------------------------
// 辅助（口径同 `editor_m15_ui_test.dart` / `editor_link_paste_v141_test.dart`）
// ---------------------------------------------------------------------------

/// 起一个挂了真实 `NoteShell` 的编辑器，并把 [content] 写入当前笔记。
Future<AppController> _pumpEditor(
  WidgetTester tester,
  AppDatabase db,
  String deviceId,
  String content,
) async {
  final repo = NoteRepository(db, deviceId: deviceId);
  final controller = AppController(repository: repo, database: db);
  await controller.bootstrap();
  await controller.createNote();
  await controller.saveNote(
    controller.selectedNoteId!,
    title: 'T',
    content: content,
    tags: const <String>[],
  );

  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: const MaterialApp(home: NoteShell()),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  return controller;
}

Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

TextEditingController _contentValue(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

/// 有界推进（**不用** `pumpAndSettle`：见文件头纪律）。
Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _pressCtrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// 切换到指定模式（宽屏模式行保留文本标签）。
Future<void> _switchMode(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await _settle(tester);
}

/// 装上平台剪贴板 mock；[html] 恒为 null 时模拟「剪贴板只有纯文本」（Sui 内部复制的真实形态）。
void _mockClipboard(
  WidgetTester tester, {
  String? html,
  String? plain,
}) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.getData') {
        final format = call.arguments as String?;
        if (format == 'text/html') return <String, dynamic>{'text': html};
        return <String, dynamic>{'text': plain};
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

// ---------------------------------------------------------------------------

void main() {
  group('PasteVerbatim（FR-122 / BR-122.1~122.3 / AC-705~AC-709）', () {
    testWidgets('格式态普通粘贴：纯文本原样插入，不转义 Markdown 字符', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v221-fmt', '前\n后');
      final ctrl = _contentValue(tester);

      const plain = '[x](y) - [ ] 任务 **粗** a*b_c';
      _mockClipboard(tester, plain: plain);

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.pump();
      await _settle(tester);

      expect(ctrl.text, '前$plain\n后',
          reason: '普通粘贴必须原样插入（FR-122 / BR-122.1）；实际=${ctrl.text}');
      expect(ctrl.text.contains(r'\[x\]'), isFalse,
          reason: 'v0.22.1 起普通粘贴不得前置反斜杠（用户报障 `[]` → `\\[\\]`）');
      await db.close();
    });

    testWidgets('源码态普通粘贴：原样插入（无转义加工，与格式态逐字节相同）', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v221-src', '前\n后');
      final ctrl = _contentValue(tester);

      const plain = '[x](y) - [ ] 任务 **粗** a*b_c';
      _mockClipboard(tester, plain: plain);

      await _switchMode(tester, '源码');
      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.pump();
      await _settle(tester);

      expect(ctrl.text, '前\n后$plain',
          reason: '源码态普通粘贴必须原样（FR-77 无转义加工 / FR-122）；实际=${ctrl.text}');
      expect(ctrl.text.contains(r'\[x\]'), isFalse,
          reason: '源码态不得出现粘贴引入的转义');
      await db.close();
    });

    testWidgets('Ctrl+Shift+V 仍是字面转义入口（格式态）', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v221-fmt-shift', '前');
      final ctrl = _contentValue(tester);

      _mockClipboard(tester, plain: '[x](y) a*b_c');

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV, shift: true);
      await tester.pump();
      await tester.pump();
      await _settle(tester);

      expect(ctrl.text, contains(r'\[x\]\(y\) a\*b\_c'),
          reason: 'Ctrl+Shift+V 必须保留逐字符转义（BR-122.3 口径不变）');
      await db.close();
    });

    testWidgets('Ctrl+Shift+V 仍是字面转义入口（源码态）', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v221-src-shift', '前');
      final ctrl = _contentValue(tester);

      _mockClipboard(tester, plain: '[x](y)');

      await _switchMode(tester, '源码');
      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV, shift: true);
      await tester.pump();
      await tester.pump();
      await _settle(tester);

      expect(ctrl.text, contains(r'\[x\]\(y\)'),
          reason: '源码态的 Ctrl+Shift+V 也走字面转义（FR-122 / AC-707）');
      await db.close();
    });

    testWidgets('只归换行：CRLF / 裸 CR → LF，不折叠空行、不补结尾换行', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v221-crlf', '前');
      final ctrl = _contentValue(tester);

      _mockClipboard(tester, plain: '甲\r\n\r\n乙\r丙');

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.pump();
      await _settle(tester);

      expect(ctrl.text, '前甲\n\n乙\n丙',
          reason: '普通粘贴只做 normalizeLineEndings（BR-122.2），不套用导入口径');
      expect(ctrl.text.contains('\r'), isFalse);
      await db.close();
    });

    testWidgets('普通粘贴一次可撤销', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v221-undo', '前\n后');
      final ctrl = _contentValue(tester);

      _mockClipboard(tester, plain: '粘贴内容');

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      // `UndoHistory` 入栈有 500ms 节流（`_kThrottleDuration`）：先让「粘贴前」的状态入栈，
      // 否则初始值会与粘贴被同一次节流合并成一步（框架行为；真实用户两次操作间隔远大于 500ms）。
      await tester.pump(const Duration(milliseconds: 600));

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.pump();
      await _settle(tester);
      expect(ctrl.text, contains('粘贴内容'));

      // `UndoHistory` 入栈有 500ms 节流（`_kThrottleDuration`）：节流期内撤销只会提交当前值、
      // 不会回退；真实用户按下撤销也在此之后。这里推进 600ms 再走产品的撤销入口。
      await tester.pump(const Duration(milliseconds: 600));

      final undo = tester.widget<TextField>(_contentField()).undoController;
      expect(undo, isNotNull, reason: '正文应挂 UndoHistoryController');
      undo!.undo();
      await tester.pump();
      expect(ctrl.text, '前\n后',
          reason: '一次撤销必须回到粘贴前逐字节状态（BR-122.4）');
      await db.close();
    });
  });
}
