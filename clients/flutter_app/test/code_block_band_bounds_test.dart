/// FR-93 / FR-94 / BR-93.1\~93.3 / BR-94.1\~94.3 / AC-537\~AC-547：
/// 格式模式**围栏代码块底色带**必须
/// ①完整落在编辑区白底内（宽屏 / 窄屏 / 缩放 / 独立窗口）；
/// ②绘制在**代码文字之下**（不得盖住代码）；③满行宽、同色源、零布局影响。
///
/// **红检基线**（`v0.16.4`）：
/// * 带宽 `paragraphWidth + 2 × 40`、依赖「编辑器裁剪」，而 `RenderEditable` 只在自身
///   有可视溢出时裁剪 → 1600×900 下左越编辑区 **23.7px**、右越窗口 **24.3px**；
/// * 底色带是 inline 占位 widget，`RenderParagraph` **先画文字再画子 widget** →
///   带**盖住代码文字**（`var a = 1;` 在带内不可见）。
///
/// **纪律**：全程**禁用** `pumpAndSettle()`（Agents.md §5.2），一律有界 `pump`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/appearance/app_palette.dart';
import 'package:sui_flutter_app/src/ui/code_block_band_painter.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';
import 'package:sui_flutter_app/src/ui/note_window.dart';

/// 含一个 5 行围栏块（开围栏 / 两行代码 / 空行 / 闭围栏）的正文。
const String _content = '前文\n\n```dart\nvar a = 1;\n\nvar b = 2;\n```\n\n后文';

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步器（Agents.md §5.2）。
Future<void> _settle(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 建库 + 建一篇含围栏块的笔记，返回控制器与笔记 id。
Future<(AppController, String)> _seed(
    WidgetTester tester, AppDatabase db) async {
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'fr93-band-bounds'),
    database: db,
  );
  addTearDown(controller.dispose);
  await controller.bootstrap();
  await controller.createNote();
  final noteId = controller.selectedNoteId!;
  await controller.saveNote(
    noteId,
    title: '底色带边界',
    content: _content,
    tags: const <String>[],
  );
  return (controller, noteId);
}

Future<AppController> _pumpShell(
  WidgetTester tester,
  AppDatabase db, {
  required Size size,
}) async {
  final (controller, _) = await _seed(tester, db);
  await tester.binding.setSurfaceSize(size);
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

Future<void> _pumpWindow(
  WidgetTester tester,
  AppDatabase db, {
  Size size = const Size(900, 700),
}) async {
  final (controller, noteId) = await _seed(tester, db);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: MaterialApp(home: SuiNoteWindow(noteId: noteId, viewId: 93)),
    ),
  );
  await _settle(tester);
}

/// 当前编辑器里的底色带绘制器。
CodeBlockBandPainter _bandPainter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(kCodeBlockBandPainterKey)).painter
        as CodeBlockBandPainter;

/// 断言底色带**与段落列宽对齐、左右各留编辑区内边距**且不出界
/// （绘制器坐标系原点 = 编辑区白底左上角）。
void _expectBandInside(CodeBlockBandPainter painter, Size box,
    {required String layout}) {
  expect(painter.enabled, isTrue, reason: '$layout：格式模式必须绘制底色带');
  expect(painter.debugBandRects, isNotEmpty,
      reason: '$layout：围栏块必须画出底色带');
  for (final band in painter.debugBandRects) {
    expect(band.left, closeTo(kEditorBodyPadding, 0.5),
        reason: '$layout：带左边界与段落对齐（编辑区左内边距处，FR-93 / AC-537）');
    expect(band.right, closeTo(box.width - kEditorBodyPadding, 0.5),
        reason: '$layout：带右边界与段落对齐（编辑区右内边距处，FR-93 / AC-537）');
    expect(band.top, greaterThanOrEqualTo(-0.5),
        reason: '$layout：带不得画到编辑区上方');
    expect(band.bottom, lessThanOrEqualTo(box.height + 0.5),
        reason: '$layout：带不得画到编辑区下方');
  }
}

void main() {
  testWidgets('宽屏主窗口：带与段落左右对齐、不越界（AC-537 / AC-540）',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpShell(tester, db, size: const Size(1600, 900));
    await _settle(tester);

    final paintBox =
        tester.renderObject<RenderBox>(find.byKey(kCodeBlockBandPainterKey));
    final editor = tester.getRect(find.byType(MarkdownEditor));
    final painter = _bandPainter(tester);
    // ignore: avoid_print
    print('FR93 wide box=${paintBox.size} editor=$editor '
        'band=${painter.debugBandRects}');

    // 绘制器即编辑区白底：两者矩形必须重合（带不越界的前提）。
    expect(paintBox.size.width, closeTo(editor.width, 1));
    expect(paintBox.size.height, closeTo(editor.height, 1));
    _expectBandInside(painter, paintBox.size, layout: '宽屏');
    expect(painter.debugBandRects.single.height, greaterThan(100),
        reason: '覆盖 5 行围栏块（含块内空行与两条围栏行）');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('窄屏单栏：带不越出窗口（AC-538）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpShell(tester, db, size: const Size(700, 600));
    await _settle(tester);

    final paintBox =
        tester.renderObject<RenderBox>(find.byKey(kCodeBlockBandPainterKey));
    final painter = _bandPainter(tester);
    // ignore: avoid_print
    print('FR93 narrow box=${paintBox.size} band=${painter.debugBandRects}');
    _expectBandInside(painter, paintBox.size, layout: '窄屏');
    final origin = tester.getRect(find.byKey(kCodeBlockBandPainterKey));
    expect(origin.left, greaterThanOrEqualTo(-0.5));
    expect(origin.right, lessThanOrEqualTo(701));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('窗口缩放后带跟随编辑区、不残留旧宽度（AC-539）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpShell(tester, db, size: const Size(1600, 900));
    await _settle(tester);

    for (final size in <Size>[
      const Size(1000, 800),
      const Size(1600, 900),
      const Size(760, 600),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pump();
      await _settle(tester);
      final paintBox =
          tester.renderObject<RenderBox>(find.byKey(kCodeBlockBandPainterKey));
      final painter = _bandPainter(tester);
      // ignore: avoid_print
      print('FR93 resize $size box=${paintBox.size} '
          'band=${painter.debugBandRects}');
      _expectBandInside(painter, paintBox.size,
          layout: '缩放 ${size.width.toInt()}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('独立笔记窗口：同一口径不越界（AC-539）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpWindow(tester, db);

    final paintBox =
        tester.renderObject<RenderBox>(find.byKey(kCodeBlockBandPainterKey));
    final painter = _bandPainter(tester);
    // ignore: avoid_print
    print('FR93 window box=${paintBox.size} band=${painter.debugBandRects}');
    _expectBandInside(painter, paintBox.size, layout: '独立窗口');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('源码模式不画带（AC-546）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final controller =
        await _pumpShell(tester, db, size: const Size(1600, 900));
    await _settle(tester);
    expect(_bandPainter(tester).debugBandRects, isNotEmpty,
        reason: '格式模式先画出带');

    await controller.setEditorMode(EditorMode.source);
    await tester.pump();
    await _settle(tester);
    final painter = _bandPainter(tester);
    expect(painter.enabled, isFalse, reason: '源码模式不画底色带（AC-546）');
    expect(painter.debugBandRects, isEmpty,
        reason: '源码模式不得输出任何带矩形（AC-546）');
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('同色源与圆角（AC-541）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpShell(tester, db, size: const Size(1600, 900));
    await _settle(tester);

    final palette =
        SuiAppearance.of(tester.element(find.byType(MarkdownEditor))).palette;
    final painter = _bandPainter(tester);
    expect(painter.surface, palette.codeSurface,
        reason: '底色仍取 palette.codeSurface（BR-81.1 / AC-541）');
    expect(painter.border, palette.codeBorder,
        reason: '边框仍取 palette.codeBorder（BR-81.1 / AC-541）');
    expect(kCodeBlockBandRadius, 6);
    expect(kCodeBlockBandPadding, 6);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('带绘制在代码文字之下、代码文字仍可见（AC-544 / AC-545 / AC-546）',
      (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    await _pumpShell(tester, db, size: const Size(1600, 900));
    await _settle(tester);

    // ① 绘制顺序：绘制器是编辑区 Stack 的**第一个**子节点，TextField 所在 Padding 在其后。
    final stack = tester.widget<Stack>(
      find
          .ancestor(
            of: find.byKey(kCodeBlockBandPainterKey),
            matching: find.byType(Stack),
          )
          .first,
    );
    expect(stack.children.first.key, kCodeBlockBandPainterKey,
        reason: '底色带必须先于 TextField 绘制（否则盖住代码文字）');
    expect(stack.children.skip(1).any((w) => w is Padding), isTrue,
        reason: 'TextField 所在的 Padding 必须在绘制器之后');
    expect(
        find.descendant(
          of: find.byType(Stack),
          matching: find.byType(TextField),
        ),
        findsWidgets);

    // ② 正文 span：内容行无逐字形底色（由带承担），但文字**不是**透明 / 零字号。
    final field = tester.widget<TextField>(find
        .descendant(
          of: find.byType(MarkdownEditor),
          matching: find.byType(TextField),
        )
        .first);
    final editing = field.controller! as MarkdownEditingController;
    final span = editing.buildTextSpan(
      context: tester.element(find.byType(MarkdownEditor)),
      style: const TextStyle(fontSize: 15, height: 1.6),
      withComposing: false,
    );
    expect(span.toPlainText().length, editing.text.length,
        reason: '偏移契约（BR-27.1 / AC-542）');
    final codeOffset = editing.text.indexOf('var a = 1;');
    var cursor = 0;
    TextStyle? codeStyle;
    void walk(InlineSpan s) {
      if (s is TextSpan) {
        final t = s.text;
        if (t != null) {
          if (codeStyle == null &&
              cursor <= codeOffset &&
              cursor + t.length > codeOffset) {
            codeStyle = s.style;
          }
          cursor += t.length;
        }
        for (final c in s.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      } else if (s is WidgetSpan) {
        cursor += 1;
      }
    }

    walk(span);
    expect(codeStyle, isNotNull);
    expect(codeStyle!.backgroundColor, isNull,
        reason: '底色只由带承担（AC-436 不回归）');
    expect(codeStyle!.color, isNot(Colors.transparent),
        reason: '代码文字不得被设为透明（否则带在文字上也看不见）');
    expect(codeStyle!.fontSize ?? 15, greaterThan(0),
        reason: '代码文字字号不得为 0');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
