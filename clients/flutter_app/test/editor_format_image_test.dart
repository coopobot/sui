/// FR-27 格式模式图片渲染与尺寸调整（editor-formatting.md §8）。
///
/// FormatImageRender：格式模式把 `![alt](url){尺寸}` 渲染为图片呈现单元，且整棵
/// span 树与正本**逐字符等长**（`WidgetSpan` 占 1 个码元 + 零宽透明文本补齐），
/// 否则 TextField 的光标定位 / 命中测试会错位（BR-27.1）。
/// ImageSelectResizeHandle：点按图片即选中并弹出尺寸条，点预设把尺寸写回正本
/// （BR-27.2）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

void main() {
  group('FormatImageRender（图片引用渲染为呈现单元，BR-27.1）', () {
    testWidgets('引用替换为 WidgetSpan，且 span 树与正本逐字符等长', (tester) async {
      final controller = MarkdownEditingController(
        text: '前 ![](http://x/a.png){width=320} 后',
      );
      controller.styled = true;
      controller.formatImageBuilder = (context, image, {bool? block}) =>
          const SizedBox(width: 40, height: 30);

      late TextSpan span;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(),
              withComposing: false,
            );
            return const SizedBox.shrink();
          }),
        ),
      );

      // 偏移契约：整棵 span 树的纯文本长度必须等于正本长度。
      expect(
        span.toPlainText().length,
        controller.text.length,
        reason: 'span 树纯文本必须与正本等长，否则光标定位会错位',
      );
      expect(span.children!.whereType<WidgetSpan>(), hasLength(1));
    });

    testWidgets('未注入构建器时引用退化为普通文本', (tester) async {
      final controller =
          MarkdownEditingController(text: '![a](http://x/a.png)');
      controller.styled = true;

      late TextSpan span;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(),
              withComposing: false,
            );
            return const SizedBox.shrink();
          }),
        ),
      );

      expect(span.children!.whereType<WidgetSpan>(), isEmpty);
      expect(span.toPlainText(), controller.text);
    });

    // 回归：BUG2「格式模式图片悬浮在整篇笔记之上」。
    // 根因是 WidgetSpan 采用中线对齐（middle），呈现单元远高于单行行高时，
    // 其顶部会被抬到字段之上。修法为行顶对齐（top），使行高**向下**扩展。
    // 见 editor-formatting.md §5.4「嵌入几何（垂直对齐）」。
    testWidgets('格式模式高图不溢出到字段之上（WidgetSpan 行顶对齐）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller =
          MarkdownEditingController(text: '前 ![](sui://deadbeef) 后');
      controller.styled = true;
      // 呈现单元远高于单行行高，构成「高图」场景（默认尺寸随容器自适应，
      // 竖向可远超一行）。
      controller.formatImageBuilder =
          (context, image, {bool? block}) => const SizedBox(
                key: ValueKey<String>('format-image'),
                width: 240,
                height: 360,
              );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              expands: true,
              maxLines: null,
              decoration: const InputDecoration(border: InputBorder.none),
            ),
          ),
        ),
      );
      await tester.pump();

      final fieldRect = tester.getRect(find.byType(TextField));
      final imageRect =
          tester.getRect(find.byKey(const ValueKey<String>('format-image')));

      // 前置条件：确实构成高图场景（高于单行行高）。
      expect(
        imageRect.height,
        greaterThan(100),
        reason: '呈现单元应远高于单行，构成高图场景',
      );
      // 核心断言：图片顶部不得溢出到字段之上（中线对齐会使 top 变负）。
      expect(
        imageRect.top,
        greaterThanOrEqualTo(fieldRect.top),
        reason: '格式模式图片必须落在字段内（行顶对齐），'
            '不得因居中对齐把顶部溢出到整篇笔记之上（BUG2）',
      );

      // 偏移契约仍须成立（BR-27.1）。
      final span = controller.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        style: const TextStyle(),
        withComposing: false,
      );
      expect(span.toPlainText().length, controller.text.length);
    });

    // 缺陷修复（§5.5 / AC-74 / AC-80）：独占块的图片引用按**块级呈现单元**布局。
    // 判定依据：引用左侧是行首、右侧是行尾（文本首尾或换行）；历史行内引用仍在
    // 同一行，保持行内呈现，正本逐字保真。
    testWidgets('独占块引用向 UI 层传 block=true，行内引用传 false', (tester) async {
      Future<bool?> blockFor(String text) async {
        bool? seen;
        final controller = MarkdownEditingController(text: text);
        controller.styled = true;
        controller.formatImageBuilder = (context, image, {bool? block}) {
          seen = block;
          return const SizedBox(width: 10, height: 10);
        };
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(builder: (context) {
              controller.buildTextSpan(
                context: context,
                style: const TextStyle(),
                withComposing: false,
              );
              return const SizedBox.shrink();
            }),
          ),
        );
        return seen;
      }

      // 独占块：引用前后即行边界（含文本首尾）。
      expect(await blockFor('![a](http://x/a.png)'), isTrue);
      expect(await blockFor('正文\n\n![a](http://x/a.png)\n\n后文'), isTrue);
      // 行内引用：同一行内还有其它文字 → 不按块级布局。
      expect(await blockFor('前 ![a](http://x/a.png) 后'), isFalse);
      expect(await blockFor('前 ![a](http://x/a.png)'), isFalse);
    });

    // 块级呈现的几何效果（缺陷 B18）：块高向下扩展，后续文字整体下移、与图片不
    // 重叠，光标可落到图片下沿之下。
    //
    // 根因：[EditableText] 未显式给定 `strutStyle` 时默认
    // `StrutStyle.fromTextStyle(style, forceStrutHeight: true)`，会把**每一行**都
    // 强制成固定行高，从而忽略行内 WidgetSpan 的实际高度 —— 块级图片溢出自己那
    // 一行、压住下方文字，光标也落不到图片下面。生产代码在 markdown_editor.dart
    // 显式传 `forceStrutHeight: false`，本用例走**真实编辑器**验证该修复。
    testWidgets('块级呈现的图片下方留出文字行高（文字整体下移）', (tester) async {
      final controller = MarkdownEditingController(
        text: '![a](sui://deadbeef)\n\n下方文字',
      );
      controller.formatImageBuilder =
          (context, image, {bool? block}) => SizedBox(
                key: const ValueKey<String>('format-image'),
                width: block == true ? double.infinity : 240,
                height: 360,
              );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: MarkdownEditor(
                controller: controller,
                mode: EditorMode.formatted,
                onChanged: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final imageRect =
          tester.getRect(find.byKey(const ValueKey<String>('format-image')));
      final editable =
          tester.allRenderObjects.whereType<RenderEditable>().first;
      // 正本文末光标（offset = text.length）——即「下方文字」之后。
      final caret = editable.getLocalRectForCaret(
        TextPosition(offset: controller.text.length),
      );
      final caretTop = editable.localToGlobal(caret.topLeft).dy;

      expect(
        caretTop,
        greaterThanOrEqualTo(imageRect.bottom - 2),
        reason: '文末光标须落在图片下沿之下，说明后续文字整体下移而非被图片遮盖'
            '（光标 y=$caretTop，图片下沿 y=${imageRect.bottom}）',
      );

      // 偏移契约仍须成立（BR-27.1）。
      final span = controller.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        style: const TextStyle(),
        withComposing: false,
      );
      expect(span.toPlainText().length, controller.text.length);
    });
  });

  group('ImageSelectResizeHandle（选中图片调尺寸，BR-27.2）', () {
    late AppDatabase db;
    late AppController controller;

    Future<void> pumpEditor(WidgetTester tester, String content) async {
      db = AppDatabase.memory();
      controller = AppController(
        repository: NoteRepository(db, deviceId: 'fr27-test'),
        database: db,
      );
      await controller.bootstrap();
      await controller.createNote();
      await controller.saveNote(
        controller.selectedNoteId!,
        title: 'T',
        content: content,
        tags: const <String>[],
      );

      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      // 首帧后放行真实异步，让附件的字节读取跑完，落到静态「加载失败」占位
      // （避免不定长转圈动画，使后续断言确定）。
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    Finder contentField() => find
        .descendant(
          of: find.byType(NoteEditor),
          matching: find.byType(TextField),
        )
        .last;

    testWidgets('点按内联图片即选中并弹出尺寸条，点「中」写回 {width=50%}', (tester) async {
      await pumpEditor(tester, '前 ![封面](sui://deadbeef) 后');

      // 初始化：引用被渲染为图片呈现单元（附件缺失 → 占位），此时未选中，
      // 尺寸条不出现（BR-27.3：字节未就绪显示占位，不阻断编辑）。
      expect(
        find.descendant(
          of: find.byType(NoteEditor),
          matching: find.byIcon(Icons.broken_image_outlined),
        ),
        findsOneWidget,
        reason: '格式模式应把引用渲染为图片呈现单元（占位）',
      );
      expect(find.text('图片尺寸'), findsNothing);

      // 点按图片 → 选中 → 尺寸条出现（BR-27.2）。
      await tester.tap(find.byIcon(Icons.broken_image_outlined));
      await tester.pump();
      expect(find.text('图片尺寸'), findsOneWidget);

      // 点「中」预设 → 尺寸写回正本属性块（ADR-007）。
      await tester.tap(find.widgetWithText(TextButton, '中'));
      await tester.pump();

      final field = tester.widget<TextField>(contentField());
      expect(field.controller!.text, contains('{width=50%}'));

      await db.close();
    });

    testWidgets('光标落入引用范围内即弹出尺寸条', (tester) async {
      await pumpEditor(tester, '前 ![封面](sui://deadbeef) 后');

      final field = tester.widget<TextField>(contentField());
      final ctrl = field.controller!;
      // 把光标放进引用跨度内（offset 8 落在 `![封面](...)` 中）。
      ctrl.selection = const TextSelection.collapsed(offset: 8);
      await tester.pump();

      expect(find.text('图片尺寸'), findsOneWidget);

      await db.close();
    });

    // 缺陷修复（§5.5 / AC-80）：独占块的图片引用在真实编辑器里按块级呈现单元
    // 布局 —— 呈现单元占满段落宽（左对齐），块高向下扩展，下方文字整体后移。
    testWidgets('独占块图片在编辑器中占满段落宽', (tester) async {
      await pumpEditor(tester, '![封面](sui://deadbeef)\n\n后文');

      final icon = find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byIcon(Icons.broken_image_outlined),
      );
      expect(icon, findsOneWidget, reason: '附件缺失时显示占位，不阻断编辑');

      // 块级呈现：图片被 Align 左对齐并撑满段落宽。
      final unit = find.ancestor(of: icon, matching: find.byType(Align)).first;
      final unitWidth = tester.getSize(unit).width;
      final fieldWidth = tester.getSize(contentField()).width;
      expect(
        unitWidth,
        greaterThan(fieldWidth * 0.8),
        reason: '块级呈现单元应占满段落宽（$unitWidth vs 段落宽 $fieldWidth）',
      );

      await db.close();
    });
  });
}
