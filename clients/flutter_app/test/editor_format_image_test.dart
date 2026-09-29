/// FR-27 格式模式图片渲染与尺寸调整（editor-formatting.md §8）。
///
/// FormatImageRender：格式模式把 `![alt](url){尺寸}` 渲染为图片呈现单元，且整棵
/// span 树与正本**逐字符等长**（`WidgetSpan` 占 1 个码元 + 零宽透明文本补齐），
/// 否则 TextField 的光标定位 / 命中测试会错位（BR-27.1）。
/// ImageSelectResizeHandle：点按图片即选中并弹出尺寸条，点预设把尺寸写回正本
/// （BR-27.2）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

void main() {
  group('FormatImageRender（图片引用渲染为呈现单元，BR-27.1）', () {
    testWidgets('引用替换为 WidgetSpan，且 span 树与正本逐字符等长', (tester) async {
      final controller = MarkdownEditingController(
        text: '前 ![](http://x/a.png){width=320} 后',
      );
      controller.styled = true;
      controller.formatImageBuilder =
          (context, image) => const SizedBox(width: 40, height: 30);

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
    testWidgets('格式模式高图不溢出到字段之上（WidgetSpan 行顶对齐）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller =
          MarkdownEditingController(text: '前 ![](sui://deadbeef) 后');
      controller.styled = true;
      // 呈现单元远高于单行行高，构成「高图」场景（默认尺寸随容器自适应，
      // 竖向可远超一行）。
      controller.formatImageBuilder = (context, image) => const SizedBox(
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

    testWidgets('点按内联图片即选中并弹出尺寸条，点「中」写回 {width=50%}',
        (tester) async {
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
  });
}
