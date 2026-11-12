/// FR-117 / ADR-042：附件「保存到本地 / 本机」的 widget 测试（AC-667\~AC-671）。
///
/// 覆盖：
/// 1. 预览弹窗「保存到本地」→ 平台层收到**规整后的文件名 + 真实字节**，Snackbar 提示路径；
/// 2. 附件卡片下载图标 → **不打开预览**也能保存；
/// 3. 用户取消 → **不提示**（BR-117.6）；
/// 4. 本机无字节 → 明确提示（BR-117.7）。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（30s 周期兜底同步会让假时钟无限排帧，
/// Agents.md §5.2）；真实 I/O（`bootstrap` / 附件入库）走 `tester.runAsync`。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/attachment_picker.dart';
import 'package:sui_flutter_app/src/platform/attachment_saver.dart';
import 'package:sui_flutter_app/src/platform/platform_seams.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

Uint8List _bytes([int n = 64]) =>
    Uint8List.fromList(List<int>.generate(n, (i) => i % 251));

String _tempDataDir(String tag) {
  final dir = Directory.systemTemp.createTempSync('sui-attach-save-$tag-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

/// 交替「真实异步推进 + 有界 pump」，等待条件成立。
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  String reason = '',
  int tries = 240,
}) async {
  for (var i = 0; i < tries; i++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  if (!condition()) fail('等待超时${reason.isEmpty ? '' : '：$reason'}');
}

Future<AppController> _pumpEditor(
  WidgetTester tester,
  AppDatabase db,
  String deviceId, {
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
      content: '正文',
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

Finder _panelItem(String filename) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(filename));

Finder _saveIcon() => find.widgetWithIcon(IconButton, Icons.download_outlined);

Future<void> _addPdfAttachment(
  WidgetTester tester,
  AppController controller,
) async {
  debugAttachmentPickerOverride = () async => [
        PickedAttachment(filename: '报告.pdf', bytes: _bytes()),
      ];
  final panelButton = find.byTooltip('附件');
  await tester.ensureVisible(panelButton);
  await tester.pump();
  await tester.tap(panelButton);
  await _settle(tester);
  await tester.tap(find.text('添加附件'));
  await _waitFor(
    tester,
    () =>
        controller.attachments.length == 1 &&
        find.text('添加中…').evaluate().isEmpty,
    reason: '等待附件添加完成',
  );
  // 卡片先异步查可用性（`检查中`），busy 时 InkWell.onTap / 保存按钮 == null；
  // 等「保存图标可点」这个**正向信号**，而不是等 `检查中` 消失（那一帧可能还没建卡片）。
  await _waitFor(
    tester,
    () =>
        _saveIcon().evaluate().isNotEmpty &&
        tester.widget<IconButton>(_saveIcon()).onPressed != null,
    reason: '等待附件可用性检查完成',
  );
}

/// 清掉「已添加 1 个附件」之类仍在排队的 SnackBar，避免保存提示被排在后面。
Future<void> _clearSnackBars(WidgetTester tester) async {
  final scaffold = find.byType(Scaffold).first;
  if (scaffold.evaluate().isEmpty) return;
  ScaffoldMessenger.of(tester.element(scaffold)).clearSnackBars();
  await tester.pump();
}

void main() {
  late AppDatabase db;

  setUp(() {
    debugAttachmentPickerOverride = null;
    debugAttachmentSaveOverride = null;
    debugSavePathOverride = null;
  });
  tearDown(() {
    debugAttachmentPickerOverride = null;
    debugAttachmentSaveOverride = null;
    debugSavePathOverride = null;
  });

  testWidgets('预览弹窗保存：文件名 / 字节透传，提示完整路径', (tester) async {
    db = AppDatabase.memory();
    final controller = await _pumpEditor(
      tester,
      db,
      'v0192-dialog',
      dataDir: _tempDataDir('dialog'),
    );
    await _addPdfAttachment(tester, controller);

    String? savedName;
    Uint8List? savedBytes;
    debugAttachmentSaveOverride =
        ({required String filename, required Uint8List bytes}) async {
      savedName = filename;
      savedBytes = bytes;
      return const AttachmentSaveResult(
        AttachmentSaveOutcome.saved,
        location: r'C:\Users\me\Downloads\报告.pdf',
      );
    };

    await tester.tap(_panelItem('报告.pdf'));
    await _waitFor(
      tester,
      () => find.text('保存到本地').evaluate().isNotEmpty,
      reason: '等待预览弹窗',
    );
    expect(find.text('用系统默认应用打开'), findsOneWidget);

    await _clearSnackBars(tester);
    await tester.tap(find.text('保存到本地'));
    await _waitFor(tester, () => savedName != null, reason: '等待保存调用');
    await _settle(tester);

    expect(savedName, '报告.pdf');
    expect(savedBytes, equals(_bytes()));
    expect(find.textContaining('已保存到'), findsOneWidget);

    await db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('附件卡片保存：不打开预览也能保存', (tester) async {
    db = AppDatabase.memory();
    final controller = await _pumpEditor(
      tester,
      db,
      'v0192-card',
      dataDir: _tempDataDir('card'),
    );
    await _addPdfAttachment(tester, controller);

    await _waitFor(
      tester,
      () =>
          _saveIcon().evaluate().isNotEmpty &&
          tester.widget<IconButton>(_saveIcon()).onPressed != null,
      reason: '等待卡片可保存（字节检查完成）',
    );

    String? savedName;
    debugAttachmentSaveOverride =
        ({required String filename, required Uint8List bytes}) async {
      savedName = filename;
      return const AttachmentSaveResult(
        AttachmentSaveOutcome.saved,
        location: '/tmp/报告.pdf',
      );
    };

    await _clearSnackBars(tester);
    await tester.tap(_saveIcon());
    await _waitFor(tester, () => savedName != null, reason: '等待保存调用');
    await _settle(tester);

    expect(savedName, '报告.pdf');
    expect(find.textContaining('已保存到'), findsOneWidget);

    await db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('取消保存：不提示错误', (tester) async {
    db = AppDatabase.memory();
    final controller = await _pumpEditor(
      tester,
      db,
      'v0192-cancel',
      dataDir: _tempDataDir('cancel'),
    );
    await _addPdfAttachment(tester, controller);

    debugAttachmentSaveOverride =
        ({required String filename, required Uint8List bytes}) async =>
            const AttachmentSaveResult(AttachmentSaveOutcome.cancelled);

    await tester.tap(_panelItem('报告.pdf'));
    await _waitFor(
      tester,
      () => find.text('保存到本地').evaluate().isNotEmpty,
      reason: '等待预览弹窗',
    );

    await _clearSnackBars(tester);
    await tester.tap(find.text('保存到本地'));
    await _settle(tester);

    expect(find.textContaining('已保存'), findsNothing);
    expect(find.textContaining('失败'), findsNothing);
    // 弹窗仍在（取消不关闭预览）。
    expect(find.text('保存到本地'), findsOneWidget);

    await db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('本机无字节：提示且不崩溃', (tester) async {
    db = AppDatabase.memory();
    final controller = await _pumpEditor(
      tester,
      db,
      'v0192-nodata',
      dataDir: _tempDataDir('nodata'),
    );
    await _addPdfAttachment(tester, controller);

    debugAttachmentSaveOverride =
        ({required String filename, required Uint8List bytes}) async =>
            const AttachmentSaveResult(AttachmentSaveOutcome.noData);

    await tester.tap(_panelItem('报告.pdf'));
    await _waitFor(
      tester,
      () => find.text('保存到本地').evaluate().isNotEmpty,
      reason: '等待预览弹窗',
    );

    await _clearSnackBars(tester);
    await tester.tap(find.text('保存到本地'));
    await _settle(tester);

    expect(find.textContaining('本机没有字节'), findsOneWidget);

    await db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('保存不改正文 / 附件映射 / 缓存占用（AC-674）', (tester) async {
    db = AppDatabase.memory();
    final controller = await _pumpEditor(
      tester,
      db,
      'v0192-db',
      dataDir: _tempDataDir('db'),
    );
    await _addPdfAttachment(tester, controller);

    final contentBefore =
        controller.noteById(controller.selectedNoteId)?.contentMarkdown;
    final attachmentsBefore =
        controller.attachments.map((a) => a.sha256).toList();
    final usageBefore = await tester.runAsync(controller.attachmentCacheUsage);

    debugAttachmentSaveOverride =
        ({required String filename, required Uint8List bytes}) async =>
            const AttachmentSaveResult(
              AttachmentSaveOutcome.saved,
              location: '/tmp/报告.pdf',
            );

    await tester.tap(_panelItem('报告.pdf'));
    await _waitFor(
      tester,
      () => find.text('保存到本地').evaluate().isNotEmpty,
      reason: '等待预览弹窗',
    );
    await _clearSnackBars(tester);
    await tester.tap(find.text('保存到本地'));
    await _settle(tester);

    final contentAfter =
        controller.noteById(controller.selectedNoteId)?.contentMarkdown;
    final attachmentsAfter =
        controller.attachments.map((a) => a.sha256).toList();
    final usageAfter = await tester.runAsync(controller.attachmentCacheUsage);

    expect(contentAfter, contentBefore, reason: '保存不改正文');
    expect(attachmentsAfter, attachmentsBefore, reason: '保存不改附件映射');
    expect(usageAfter, usageBefore, reason: '副本不计入附件缓存');

    await db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
