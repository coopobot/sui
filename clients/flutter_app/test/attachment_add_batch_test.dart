/// 补丁 `v0.16.3`：多附件添加的**进度反馈、防重入与列表 / 正本一致** widget 测试
/// （FR-91 / BR-91.1\~91.6 / AC-516\~AC-524）。
///
/// 复现的用户现象：一次选多个大附件时，附件弹框在整个批次结束前**一直是空态**，
/// 用户反复点「添加附件」→ 多个批次并发 → 后一批的正文快照覆盖前一批 → **附件列表
/// 里的条目与正文引用对不上**。
///
/// 覆盖：
/// 1. 选完文件后面板**立即**列出待添加项、按钮进入「正在添加…」并置灰；
/// 2. 批次进行中连点入口**不会**再开第二批（选择器只被调用一次）；
/// 3. 批次结束后正文引用集合与附件列表**一一对应**、各出现一次；
/// 4. 插入形态随类型（图片 `![…]`、PDF `[…](sui://…)`）。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（30s 周期兜底同步会让假时钟无限排帧，
/// Agents.md §5.2）；真实 I/O（`bootstrap` / 附件字节入库）走 `tester.runAsync`。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/attachment_picker.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

Uint8List _bytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => i % 251));

/// 一次性数据目录（测试结束即删）：附件字节要落真实磁盘。
String _tempDataDir(String tag) {
  final dir = Directory.systemTemp.createTempSync('sui-attach-$tag-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

Future<AppController> _pumpEditor(
  WidgetTester tester,
  AppDatabase db,
  String deviceId,
  String content, {
  required String dataDir,
}) async {
  final repo = NoteRepository(db, deviceId: deviceId);
  final controller = AppController(
    repository: repo,
    database: db,
    dataDir: dataDir,
  );
  await tester.runAsync(controller.bootstrap);
  await tester.runAsync(() async {
    await controller.createNote();
    await controller.saveNote(
      controller.selectedNoteId!,
      title: 'T',
      content: content,
      tags: const <String>[],
    );
  });

  await tester.binding.setSurfaceSize(const Size(1200, 800));
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

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// 交替「真实异步推进 + 有界 pump」，等待条件成立（真实 I/O 只靠假时钟不会完成）。
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  String reason = '',
  int tries = 200,
}) async {
  for (var i = 0; i < tries; i++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  if (!condition()) {
    fail('等待超时${reason.isEmpty ? '' : '：$reason'}');
  }
}

Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

TextEditingController _contentValue(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

Future<void> _openPanel(WidgetTester tester) async {
  final btn = find.byTooltip('附件');
  await tester.ensureVisible(btn);
  await tester.pump();
  await tester.tap(btn);
  await _settle(tester);
}

Finder _pickImageButton() =>
    find.widgetWithIcon(IconButton, Icons.image_outlined);

void main() {
  group('AttachmentAddBatch（v0.16.3 / FR-91 / AC-516~AC-524）', () {
    late AppDatabase db;

    setUp(() {
      // 测试接缝：不弹真实系统文件选择器（生产代码从不写入该变量）。
      debugAttachmentPickerOverride = null;
    });
    tearDown(() {
      debugAttachmentPickerOverride = null;
    });

    testWidgets('选完文件即列出待添加项；按钮进入进行态，完成后转为卡片', (tester) async {
      db = AppDatabase.memory();
      final dataDir = _tempDataDir('progress');
      await _pumpEditor(tester, db, 'v0163-progress', '正文', dataDir: dataDir);
      await _openPanel(tester);

      final completer = Completer<List<PickedAttachment>>();
      debugAttachmentPickerOverride = () => completer.future;

      await tester.tap(find.text('添加附件'));
      await tester.pump();

      // AC-516 / AC-518：选文件阶段就进入进行态，不再是「点了没反应」。
      expect(find.text('正在添加…'), findsOneWidget, reason: '按钮应显示进行态');
      final busyButton = find.widgetWithText(TextButton, '正在添加…');
      expect(tester.widget<TextButton>(busyButton).onPressed, isNull,
          reason: '批次中「添加附件」必须置灰');

      completer.complete([
        PickedAttachment(filename: '报告.pdf', bytes: _bytes(64)),
      ]);
      await tester.pump();

      // AC-516：选完文件后**下一帧**就能在面板看到待添加项（而不是空态）。
      expect(find.text('报告.pdf'), findsOneWidget,
          reason: '待添加文件应立即出现在面板');
      expect(find.text('添加中…'), findsOneWidget, reason: '待添加项应带进行态');
      expect(find.textContaining('暂无附件'), findsNothing,
          reason: '批次进行中不得回到空态');

      // AC-517：完成后待添加项换成正常卡片、计数递增。
      await _waitFor(
        tester,
        () => find.text('添加中…').evaluate().isEmpty,
        reason: '等待附件添加完成',
      );
      expect(find.text('1 个'), findsOneWidget, reason: '计数应为 1');
      expect(find.text('添加附件'), findsOneWidget, reason: '批次结束后恢复可点');
      expect(_contentValue(tester).text, contains('](sui://'),
          reason: '正文应已插入引用');

      await tester.tap(find.text('关闭'));
      await _settle(tester);
      await db.close();
    });

    testWidgets('连点入口只跑一批：不重复插入引用，列表与正本一一对应', (tester) async {
      db = AppDatabase.memory();
      final dataDir = _tempDataDir('reentry');
      final controller =
          await _pumpEditor(tester, db, 'v0163-reentry', '正文', dataDir: dataDir);

      var pickerCalls = 0;
      final completer = Completer<List<PickedAttachment>>();
      debugAttachmentPickerOverride = () {
        pickerCalls++;
        return completer.future;
      };

      final btn = _pickImageButton();
      await tester.ensureVisible(btn);
      await tester.pump();
      await tester.tap(btn);
      await tester.pump();

      // AC-519：批次进行中入口置灰，连点不再触发选择器。
      expect(pickerCalls, 1);
      expect(tester.widget<IconButton>(btn).onPressed, isNull,
          reason: '批次中工具栏「插入图片」必须置灰');
      await tester.tap(btn, warnIfMissed: false);
      await tester.pump();
      expect(pickerCalls, 1, reason: '置灰后连点不得再开第二批');

      completer.complete([
        PickedAttachment(filename: 'a.png', bytes: _bytes(32)),
        PickedAttachment(filename: 'b.pdf', bytes: _bytes(48)),
      ]);

      await _waitFor(
        tester,
        () => controller.attachments.length == 2 && !_attachingOf(tester),
        reason: '等待两个附件都添加完成',
      );

      // AC-521 / AC-522：正本引用集合 == 附件列表 sha256 集合，且各恰好一次。
      final text = _contentValue(tester).text;
      final refs = EditorFormat.attachmentRefs(text);
      final attachments = controller.attachments;
      expect(attachments, hasLength(2), reason: '附件列表应有两条');
      expect(refs, hasLength(2), reason: '正文应恰好两条引用');
      expect(
        refs.map((r) => r.sha256).toSet(),
        attachments.map((a) => a.sha256).toSet(),
        reason: '引用与附件列表必须一一对应（不多不少）',
      );

      await db.close();
    });

    testWidgets('插入形态随类型：图片 ![..]、PDF [..](sui://..)', (tester) async {
      db = AppDatabase.memory();
      final dataDir = _tempDataDir('shape');
      final controller =
          await _pumpEditor(tester, db, 'v0163-shape', '正文', dataDir: dataDir);

      final completer = Completer<List<PickedAttachment>>();
      debugAttachmentPickerOverride = () => completer.future;

      final btn = _pickImageButton();
      await tester.ensureVisible(btn);
      await tester.pump();
      await tester.tap(btn);
      await tester.pump();

      completer.complete([
        PickedAttachment(filename: '报告.pdf', bytes: _bytes(64)),
        PickedAttachment(filename: '图片.png', bytes: _bytes(32)),
      ]);

      await _waitFor(
        tester,
        () => controller.attachments.length == 2 && !_attachingOf(tester),
        reason: '等待两个附件都添加完成',
      );

      // AC-524：PDF 走附件链接（附件卡片），图片走图片引用。
      final text = _contentValue(tester).text;
      expect(text, contains('[报告.pdf](sui://'), reason: 'PDF 必须是附件链接形态');
      expect(text, isNot(contains('![报告.pdf]')),
          reason: 'PDF 不得写成图片引用（会渲染成坏图占位）');
      expect(text, contains('![图片.png](sui://'), reason: '图片保持图片引用');

      final refs = EditorFormat.attachmentRefs(text);
      expect(refs.firstWhere((r) => r.label == '报告.pdf').isImage, isFalse);
      expect(refs.firstWhere((r) => r.label == '图片.png').isImage, isTrue);

      await db.close();
    });
  });
}

/// 工具栏「插入图片」按钮是否仍处于禁用（进行中）态。
bool _attachingOf(WidgetTester tester) {
  final btn = _pickImageButton();
  if (btn.evaluate().isEmpty) return false;
  return tester.widget<IconButton>(btn.first).onPressed == null;
}
