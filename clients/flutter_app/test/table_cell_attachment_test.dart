/// M9 补丁 v0.10.6：**表格单元格内附件的原子呈现与编辑** widget 测试
/// （editor-formatting.md §12.1.2 / FR-46 / FR-47 / BR-44.8 / BR-46.6 / AC-140）。
///
/// 覆盖三件事：
/// 1. 单元格内的附件引用**始终以原子呈现单元渲染**（图片 / 附件卡片），**不再露出原始 Markdown
///    文本**（含 `sui://` 之后的 64 位 sha256 长串）；span 树与控制器文本**等长**（BR-27.1 偏移契约）。
/// 2. 单元格内 `Backspace` / `Delete` **在本格内恢复生效**（逐字符删除并即时回写正本），
///    且**不冒泡**到外层编辑器破坏表结构。
/// 3. 命中附件引用时**整块删除**（一次删除整个引用，不逐字符）；单击呈现单元为**选中**
///    （光标落到引用末尾）、双击入口已接线（打开预览 / 系统应用，FR-47）。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（30s 周期兜底同步会让假时钟无限排帧，Agents.md §5.2）；
/// 真实 I/O（`bootstrap` / 附件字节入库 / 读字节）一律走 `tester.runAsync`。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/format_table.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// 起一个挂了真实 `NoteShell` 的编辑器（含真实数据目录，供附件字节入库）。
///
/// `bootstrap` / `createNote` / `saveNote` / 附件字节入库都是真实 I/O，故一律包在
/// `tester.runAsync` 内（否则假时钟下永不完成）。
Future<AppController> _pumpEditor(
  WidgetTester tester,
  AppDatabase db,
  String deviceId,
  String content, {
  required String dataDir,
  Future<void> Function(AppController controller, NoteRepository repo)? seed,
  String? attachmentName,
  Uint8List? attachmentBytes,
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
    if (attachmentBytes != null) {
      await controller.addAttachmentFromBytes(
        noteId: controller.selectedNoteId!,
        filename: attachmentName ?? '附件',
        bytes: attachmentBytes,
      );
    }
    if (seed != null) await seed(controller, repo);
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

/// 一次性数据目录（测试结束即删）。
String _tempDataDir(String tag) {
  final dir = Directory.systemTemp.createTempSync('sui-cell-$tag-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir.path;
}

Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

/// 构造一张**可解码**的最小 PNG（纯色），用于让 `Image.memory` 拿到**真实像素尺寸**
/// ——格内图片溢出的复现前提正是「真实尺寸的图片」。
Uint8List _pngBytes(int width, int height) {
  final raw = <int>[];
  for (var y = 0; y < height; y++) {
    raw.add(0); // 每行的 filter 字节：none
    for (var x = 0; x < width; x++) {
      raw
        ..add(200)
        ..add(30)
        ..add(30);
    }
  }
  final idat = ZLibEncoder().convert(Uint8List.fromList(raw));
  final out = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  void chunk(String type, List<int> data) {
    final body = <int>[...type.codeUnits, ...data];
    out
      ..addAll(_be32(data.length))
      ..addAll(body)
      ..addAll(_be32(_crc32(body)));
  }

  // PNG 头：宽 / 高（大端）+ 位深 8 + 颜色类型 2（truecolor）+ 压缩 / 过滤 / 隔行扫描。
  chunk('IHDR', <int>[..._be32(width), ..._be32(height), 8, 2, 0, 0, 0]);
  chunk('IDAT', idat);
  chunk('IEND', const <int>[]);
  return Uint8List.fromList(out);
}

List<int> _be32(int v) =>
    <int>[(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 等图片**真正解码完成**（render box 高度 > 1）——解码是异步的，只等 widget 出现不够，
/// 而本次缺陷恰恰发生在「解码后尺寸突变」这一刻。
Future<void> _waitImageDecoded(WidgetTester tester, Finder img) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    if (img.evaluate().isNotEmpty && tester.getSize(img).height > 1) return;
  }
  fail('超时：单元格内图片未完成解码');
}

TextEditingController _contentValue(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

/// 某个单元格的 `TextField` 控制器（单元格键为 `sui-table-<行>-<列>`，表头行为 `-1`）。
TextEditingController _cellController(WidgetTester tester, String cellKey) {
  final field = find.descendant(
    of: find.byKey(ValueKey<String>(cellKey)),
    matching: find.byType(TextField),
  );
  return tester.widget<TextField>(field).controller!;
}

Finder _inCell(String cellKey, Finder matching) => find.descendant(
      of: find.byKey(ValueKey<String>(cellKey)),
      matching: matching,
    );

/// 有界推进（替代 `pumpAndSettle()`）。
Future<void> _settle(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 16),
  int frames = 30,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 交替推进真实 I/O 与假时钟，直到 [condition] 成立。
Future<void> _pumpUntil(
  WidgetTester tester,
  Future<bool> Function() condition, {
  required String describe,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final ok = await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      return condition();
    });
    if (ok ?? false) {
      await tester.pump();
      return;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('超时（${timeout.inSeconds}s）：$describe');
}

void main() {
  group('TableCellAttachmentUnit（§12.1.2 / FR-46 / BR-46.6 / AC-140）', () {
    testWidgets('单元格内附件渲染为原子呈现单元，不再露出原始 Markdown（含偏移契约）',
        (tester) async {
      final db = AppDatabase.memory();
      final dataDir = _tempDataDir('unit');
      final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final sha = sha256Hex(bytes);
      final linkSha = 'a1' * 32;
      final src =
          '| A | B |\n| --- | --- |\n| ![图](sui://$sha) | [文档](sui://$linkSha) |';

      await _pumpEditor(
        tester,
        db,
        'm9t12-cellunit',
        src,
        dataDir: dataDir,
        attachmentName: '图.png',
        attachmentBytes: bytes,
        seed: (c, repo) async {
          // 链接型附件只挂元数据（渲染卡片不需要字节）。
          await repo.addAttachment(
            noteId: c.selectedNoteId!,
            filename: '文档.pdf',
            mimeKind: 'document',
            sha256: linkSha,
            byteSize: 2048,
          );
          await c.refreshAttachments(c.selectedNoteId!);
        },
      );

      final ctrl = _contentValue(tester);
      expect(ctrl.text, src, reason: '渲染属视图层行为，不得改动正本一字');

      const imageCell = 'sui-table-0-0';
      final cellController = _cellController(tester, imageCell);
      expect(
        cellController,
        isA<TableCellEditingController>(),
        reason: '单元格应使用专用控制器渲染附件原子单元',
      );
      final span = (cellController as TableCellEditingController).buildTextSpan(
        context: tester.element(find.byKey(const ValueKey<String>(imageCell))),
        style: null,
        withComposing: false,
      );
      expect(
        span.children!.whereType<WidgetSpan>().length,
        1,
        reason: '图片引用折叠为一个 WidgetSpan 原子单元',
      );
      expect(
        span.toPlainText().length,
        cellController.text.length,
        reason: 'span 树必须与控制器文本等长，否则光标 / 命中测试错位（BR-27.1）',
      );
      expect(
        span.toPlainText().contains('sui://'),
        isFalse,
        reason: '原始 Markdown 引用（含 64 位 sha256）不再作为文本渲染',
      );

      // 附件字节就绪后，单元格内应真的渲染出图片。
      await _pumpUntil(
        tester,
        () async => _inCell(imageCell, find.byType(Image)).evaluate().isNotEmpty,
        describe: '单元格内图片单元渲染',
      );
      expect(
        _inCell(imageCell, find.byType(Image)),
        findsOneWidget,
        reason: '图片引用应在单元格内渲染为图片，而非文本',
      );

      // 链接型：渲染为附件卡片（回形针图标 + 文件名），同样不是文本引用。
      const linkCell = 'sui-table-0-1';
      expect(
        _inCell(linkCell, find.byIcon(Icons.attach_file)),
        findsOneWidget,
        reason: '附件链接应渲染为附件卡片',
      );
      expect(_inCell(linkCell, find.text('文档')), findsOneWidget);
      final linkSpan =
          (_cellController(tester, linkCell) as TableCellEditingController)
              .buildTextSpan(
        context: tester.element(find.byKey(const ValueKey<String>(linkCell))),
        style: null,
        withComposing: false,
      );
      expect(linkSpan.toPlainText().contains('sui://'), isFalse);

      await db.close();
    });

    testWidgets('单元格内 Backspace / Delete 在本格内生效，且不冒泡破坏表结构',
        (tester) async {
      final db = AppDatabase.memory();
      final dataDir = _tempDataDir('del');
      const src = '| A | B |\n| --- | --- |\n| abcd | 2 |';
      await _pumpEditor(tester, db, 'm9t12-celldel', src, dataDir: dataDir);
      final ctrl = _contentValue(tester);
      const cellKey = 'sui-table-0-0';

      await tester.tap(find.byKey(const ValueKey<String>(cellKey)));
      await tester.pump();
      final cell = _cellController(tester, cellKey);
      cell.selection = const TextSelection.collapsed(offset: 4);
      await tester.pump();

      // 退格：旧实现无条件吞键，单元格内根本删不掉字符。
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(cell.text, 'abc', reason: '退格应在单元格内逐字符生效（BR-44.8）');
      expect(
        ctrl.text,
        '| A | B |\n| --- | --- |\n| abc | 2 |',
        reason: '单元格改动应即时回写正本',
      );

      // 删空后再连按退格：不得冒泡到外层编辑器改动表格正本。
      for (var i = 0; i < 5; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
      }
      expect(cell.text, '', reason: '空单元格按退格应无操作');
      expect(
        ctrl.text,
        '| A | B |\n| --- | --- |\n|  | 2 |',
        reason: '空单元格退格不得冒泡到外层编辑器（表结构逐字不变）',
      );

      // Delete：光标在起点时向后删除同样生效。
      await tester.enterText(find.byKey(const ValueKey<String>(cellKey)), 'xy');
      await tester.pump();
      final cell2 = _cellController(tester, cellKey);
      cell2.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(cell2.text, 'y', reason: 'Delete 应在单元格内逐字符生效');

      await db.close();
    });

    testWidgets('单元格内附件整块删除：退格落在引用末尾一次删掉整个引用', (tester) async {
      final db = AppDatabase.memory();
      final dataDir = _tempDataDir('atomic');
      final linkSha = 'b2' * 32;
      final src = '| A | B |\n| --- | --- |\n| 前文[文档](sui://$linkSha) | 2 |';
      await _pumpEditor(tester, db, 'm9t12-cellatomic', src, dataDir: dataDir);
      final ctrl = _contentValue(tester);
      const cellKey = 'sui-table-0-0';

      await tester.tap(find.byKey(const ValueKey<String>(cellKey)));
      await tester.pump();
      final cell =
          _cellController(tester, cellKey) as TableCellEditingController;
      final refs = cell.attachmentRefs;
      expect(refs, hasLength(1), reason: '单元格显示文本中应识别出 1 个附件引用');

      // 退格落在引用末尾边界 → 整块删除（不逐字符吃掉 `)`）。
      cell.selection = TextSelection.collapsed(offset: refs.first.end);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(cell.text, '前文', reason: '退格落在引用末尾应整块删除引用（BR-46.1 / BR-46.2）');
      expect(
        ctrl.text,
        '| A | B |\n| --- | --- |\n| 前文 | 2 |',
        reason: '整块删除应即时回写正本且不留残字',
      );

      await db.close();
    });

    testWidgets('单击呈现单元 = 选中（光标落到引用末尾），双击入口已接线', (tester) async {
      final db = AppDatabase.memory();
      final dataDir = _tempDataDir('select');
      final linkSha = 'c3' * 32;
      final src = '| A | B |\n| --- | --- |\n| [文档](sui://$linkSha) | 2 |';
      await _pumpEditor(
        tester,
        db,
        'm9t12-cellselect',
        src,
        dataDir: dataDir,
        seed: (c, repo) async {
          await repo.addAttachment(
            noteId: c.selectedNoteId!,
            filename: '文档.pdf',
            mimeKind: 'document',
            sha256: linkSha,
            byteSize: 2048,
          );
          await c.refreshAttachments(c.selectedNoteId!);
        },
      );
      const cellKey = 'sui-table-0-0';

      final card = _inCell(cellKey, find.byIcon(Icons.attach_file));
      expect(card, findsOneWidget);

      // 双击入口：卡片外层 GestureDetector 已接上 onDoubleTap（打开预览 / 系统应用，FR-47）。
      final detector = tester.widget<GestureDetector>(
        find.ancestor(of: card, matching: find.byType(GestureDetector)).first,
      );
      expect(detector.onDoubleTap, isNotNull, reason: '双击应打开附件（FR-47）');

      // 单击 = 选中：光标落到引用末尾。
      // 注意：呈现单元同时接了 `onDoubleTap`（打开附件），故 `onTap` 须等**双击超时**
      // 过后才触发——有界推进越过 300ms（不用 pumpAndSettle，见文件头纪律）。
      final cell =
          _cellController(tester, cellKey) as TableCellEditingController;
      final ref = cell.attachmentRefs.single;
      cell.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        _cellController(tester, cellKey).selection.baseOffset,
        ref.end,
        reason: '单击呈现单元应把光标落到引用末尾（与正文口径一致）',
      );

      await db.close();
    });

    testWidgets('单元格内图片以固定尺寸盒子呈现、完整落在格内（不溢出，§12.1.4 ⑫）',
        (tester) async {
      final db = AppDatabase.memory();
      final dataDir = _tempDataDir('fitimg');
      // 800×1200 的大图：若不限尺寸，会远大于单元格。
      final bytes = _pngBytes(800, 1200);
      final sha = sha256Hex(bytes);
      final src = '| A | B |\n| --- | --- |\n| ![图](sui://$sha) | 2 |\n| 3 | 4 |';
      await _pumpEditor(
        tester,
        db,
        'm9t12-cellfitimg',
        src,
        dataDir: dataDir,
        attachmentName: 'big.png',
        attachmentBytes: bytes,
      );

      const cellKey = 'sui-table-0-0';
      final img = _inCell(cellKey, find.byType(Image));
      await _waitImageDecoded(tester, img);

      final imageRect = tester.getRect(img);
      final cellRect = tester.getRect(find.byKey(const ValueKey<String>(cellKey)));
      expect(
        imageRect.height,
        80,
        reason: '格内图片按固定高度 80 呈现（尺寸自首帧稳定，不随异步解码突变）',
      );
      expect(
        imageRect.width,
        lessThanOrEqualTo(cellRect.width),
        reason: '格内图片宽度不得超过单元格（列宽）',
      );
      // 四边均须落在单元格内——旧实现图片 180 高、行高仅 29，上下各溢出约 75px。
      expect(imageRect.top, greaterThanOrEqualTo(cellRect.top),
          reason: '图片上边界不得溢出单元格');
      expect(imageRect.bottom, lessThanOrEqualTo(cellRect.bottom),
          reason: '图片下边界不得溢出单元格（行高由单元格最小高度兜底）');
      expect(imageRect.left, greaterThanOrEqualTo(cellRect.left));
      expect(imageRect.right, lessThanOrEqualTo(cellRect.right));

      // 正本一字不改
      expect(_contentValue(tester).text, src);
      await db.close();
    });

    testWidgets('超长文件名的附件卡片不横向溢出（省略号截断，§12.1.4 ⑫）',
        (tester) async {
      final db = AppDatabase.memory();
      final dataDir = _tempDataDir('fitcard');
      final linkSha = 'e5' * 32;
      const longName = '斯坦福商业决策课（斯坦福大学战略决策和风险管理（SDRM）认证项目教材）.pdf';
      final src = '| A | B |\n| --- | --- |\n| 1 | [$longName](sui://$linkSha) |';
      await _pumpEditor(tester, db, 'm9t12-cellfitcard', src, dataDir: dataDir);

      const cellKey = 'sui-table-0-1';
      final cardIcon = _inCell(cellKey, find.byIcon(Icons.attach_file));
      expect(cardIcon, findsOneWidget);
      final card = find.ancestor(of: cardIcon, matching: find.byType(Row)).first;
      final cardRect = tester.getRect(card);
      final cellRect = tester.getRect(find.byKey(const ValueKey<String>(cellKey)));

      expect(
        cardRect.right,
        lessThanOrEqualTo(cellRect.right),
        reason: '卡片不得溢出单元格右边界（旧实现 RenderFlex overflowed 315px）',
      );
      expect(cardRect.width, lessThanOrEqualTo(cellRect.width));
      // 长名被截断：卡片内文本不应等于完整文件名
      final label = tester.widget<Text>(
        find.descendant(of: card, matching: find.byType(Text)).first,
      );
      expect(label.overflow, TextOverflow.ellipsis, reason: '长文件名须以省略号截断');
      expect(label.maxLines, 1);

      await db.close();
    });
  });
}
