/// B17 / AC-135 回归：窄屏编辑区采用**紧凑模式行**（三态只留图标、与「历史 / 导出」
/// 压成一行并收紧上下留白），**保留格式工具栏**；常驻底部的附件条移除，改由格式
/// 工具栏「附件」按钮弹出**附件面板**（ui-spec §4.1 / §5）。
///
/// 判据是**编辑区自身宽度**而非平台（ui-spec §4.1）：`NoteEditor` 内 `LayoutBuilder`
/// 以 520 为阈值在紧凑 / 宽屏两套排布间切换。桌面壳层编辑区约 612px、手机竖屏约
/// 360~430px，故用 400（紧凑）与 1200（宽屏）两个画布宽度分别验证。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';

/// 在指定画布尺寸下渲染真实 [NoteEditor]（含一篇已选中笔记）。
Future<AppController> _pumpEditor(WidgetTester tester, Size size) async {
  final db = AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'layout-test'),
    database: db,
  );
  addTearDown(db.close);
  await controller.bootstrap();
  await controller.createNote(title: '布局');

  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const Scaffold(body: NoteEditor()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

SegmentedButton<EditorMode> _modeSelector(WidgetTester tester) =>
    tester.widget<SegmentedButton<EditorMode>>(
      find.byType(SegmentedButton<EditorMode>),
    );

void main() {
  testWidgets('窄屏：三态切换只留图标，与「历史 / 导出」压成一行', (tester) async {
    await _pumpEditor(tester, const Size(400, 800));

    final selector = _modeSelector(tester);
    expect(selector.segments.length, 3);
    for (final s in selector.segments) {
      expect(s.label, isNull, reason: '窄屏三态不显示文本标签，避免换行吃掉编辑高度');
      expect(s.icon, isNotNull);
    }

    // 紧凑模式行是单行（Row），不是会换行的 Wrap。
    expect(
      find.ancestor(
        of: find.byType(SegmentedButton<EditorMode>),
        matching: find.byType(Wrap),
      ),
      findsNothing,
      reason: '窄屏模式行应为单行紧凑排布，而非可能换行的 Wrap',
    );

    // 右侧仍保留「历史 / 导出」两个入口。
    expect(find.byTooltip('版本历史'), findsOneWidget);
    expect(find.byTooltip('导出 Markdown'), findsOneWidget);

    // 保留格式工具栏：窄屏不砍编辑能力（请求 2）。
    // 悬浮提示现带**键位说明**（BR-23.11），故按图标定位按钮（与提示文案解耦）。
    expect(find.byIcon(Icons.format_bold), findsOneWidget);
  });

  testWidgets('宽屏：三态保留文本标签', (tester) async {
    await _pumpEditor(tester, const Size(1200, 800));

    final selector = _modeSelector(tester);
    for (final s in selector.segments) {
      expect(s.label, isNotNull, reason: '宽屏三态应保留文本标签，入口不缩水');
    }
    expect(find.text('格式'), findsOneWidget);
    expect(find.text('源码'), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
  });

  testWidgets('附件改由格式工具栏「附件」按钮弹出面板（非常驻底部）', (tester) async {
    await _pumpEditor(tester, const Size(400, 800));

    // 弹出前：编辑区内没有常驻附件条 / 附件文案，也没有弹窗。
    expect(find.textContaining('暂无附件'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);

    // 格式工具栏里的「附件」按钮（曾常驻底部）。
    final attach = find.byTooltip('附件');
    expect(attach, findsOneWidget, reason: '附件入口应落在格式工具栏');
    await tester.ensureVisible(attach);
    await tester.pumpAndSettle();

    await tester.tap(attach);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('附件'), findsOneWidget); // 面板标题
    expect(find.textContaining('暂无附件'), findsOneWidget);
    expect(find.text('添加附件'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    // 关闭后回到编辑态。
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
