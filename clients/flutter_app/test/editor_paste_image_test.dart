/// 补丁 `v0.22.2`：**剪贴板截图直接粘贴**（FR-123 / BR-123.1\~123.8 / AC-713\~AC-721）。
///
/// 背景：截图工具把截图放进剪贴板的**位图**里（PNG 注册格式 / `CF_DIB`），
/// 而 Flutter 的剪贴板 API 只承载文本 → 旧版按 `Ctrl+V` **没有任何反应**。
///
/// 覆盖的冻结口径：
/// * 剪贴板只有位图 → 存**附件**并插入 `![截图-<时间戳>.png|bmp](sui://<sha256>)`（格式态 / 源码态同口径）；
/// * HTML 只剩**本地图片引用**（`file://`）→ 以位图为准，正本**不含** `file://`；
/// * HTML 只剩**远端图片**（`https://`）→ 保留原地址、不新增附件（FR-27 不变）；
/// * **文本优先**：有纯文本时按文本粘贴，不额外插图；
/// * **纯文本粘贴**（`Ctrl+Shift+V`）不读位图；
/// * 粘贴截图是一次可撤销编辑；扩展名按字节魔数判定。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（Agents.md §5.2），一律有界 `pump`。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/clipboard_image.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

// ---------------------------------------------------------------------------
// 夹具与辅助
// ---------------------------------------------------------------------------

/// 1×1 透明 PNG（标准最小样本，Skia 可解码）。
Uint8List _pngBytes() => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// 1×1 24bpp BMP（模拟原生侧把 `CF_DIB` 补上 `BITMAPFILEHEADER` 后的产物）。
Uint8List _bmpBytes() {
  final b = BytesBuilder();
  b.add(<int>[0x42, 0x4D]); // 'BM'
  b.add(<int>[58, 0, 0, 0]); // bfSize = 14 + 40 + 4
  b.add(<int>[0, 0, 0, 0]); // bfReserved1/2
  b.add(<int>[54, 0, 0, 0]); // bfOffBits = 14 + 40
  b.add(<int>[40, 0, 0, 0]); // biSize
  b.add(<int>[1, 0, 0, 0]); // biWidth
  b.add(<int>[1, 0, 0, 0]); // biHeight
  b.add(<int>[1, 0]); // biPlanes
  b.add(<int>[24, 0]); // biBitCount
  b.add(<int>[0, 0, 0, 0]); // biCompression = BI_RGB
  b.add(<int>[4, 0, 0, 0]); // biSizeImage
  b.add(<int>[0, 0, 0, 0]); // biXPelsPerMeter
  b.add(<int>[0, 0, 0, 0]); // biYPelsPerMeter
  b.add(<int>[0, 0, 0, 0]); // biClrUsed
  b.add(<int>[0, 0, 0, 0]); // biClrImportant
  b.add(<int>[0x00, 0x00, 0xFF, 0x00]); // BGR + padding
  return b.toBytes();
}

Future<AppController> _pumpEditor(
  WidgetTester tester,
  AppDatabase db,
  String deviceId,
  String content,
) async {
  final repo = NoteRepository(db, deviceId: deviceId);
  final dir = Directory.systemTemp.createTempSync('sui_paste_image_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final controller =
      AppController(repository: repo, database: db, dataDir: dir.path);
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

Future<void> _switchMode(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
  await _settle(tester);
}

/// 文本剪贴板 mock（位图走 `debugClipboardImageOverride` 接缝，不碰原生通道）。
void _mockClipboard(WidgetTester tester, {String? html, String? plain}) {
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

void _useClipboardImage(Uint8List bytes) {
  debugClipboardImageOverride = () async => bytes;
  addTearDown(() => debugClipboardImageOverride = null);
}

// ---------------------------------------------------------------------------

void main() {
  group('ClipboardImageExtension（BR-123.3 / AC-714）', () {
    test('按魔数判定 PNG / BMP，不认识返回 null', () {
      expect(clipboardImageExtension(_pngBytes()), 'png');
      expect(clipboardImageExtension(_bmpBytes()), 'bmp');
      expect(clipboardImageExtension(Uint8List.fromList(<int>[1, 2, 3])), isNull,
          reason: '判不出来必须放弃（绝不写坏引用）');
    });
  });

  group('PasteClipboardImage（FR-123 / AC-713~AC-721）', () {
    testWidgets('格式态：剪贴板只有 PNG 位图 → 落附件并插入图片引用', (tester) async {
      final db = AppDatabase.memory();
      final controller = await _pumpEditor(tester, db, 'v222-fmt', '前\n后');
      final ctrl = _contentValue(tester);
      _useClipboardImage(_pngBytes());
      _mockClipboard(tester);

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      // 附件入库是**真实 IO**（sha256 / 写 blob / drift）：widget 测试的假时钟不推进真实 IO，
      // 必须让事件循环跑真实时间、并反复 flush 微任务（Agents.md §5.18）。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.idle();
        await tester.pump();
      }
      await _settle(tester);

      final match = RegExp(r'!\[([^\]]+)\]\(sui://([0-9a-f]{64})\)')
          .firstMatch(ctrl.text);
      expect(match, isNotNull, reason: '应写入附件引用：${ctrl.text}');
      expect(match!.group(1), startsWith('截图-'));
      expect(match.group(1), endsWith('.png'));
      expect(controller.attachments, hasLength(1),
          reason: '位图必须真的入库（附件面板同口径）');
      expect(controller.attachments.single.sha256, match.group(2));
      expect(controller.attachments.single.filename, match.group(1));
      expect(controller.attachments.single.mimeKind, 'image');
      await db.close();
    });

    testWidgets('DIB→BMP 兜底：位图是 BMP 时扩展名 .bmp', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v222-bmp', '前');
      final ctrl = _contentValue(tester);
      _useClipboardImage(_bmpBytes());
      _mockClipboard(tester);

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      // 附件入库是**真实 IO**（sha256 / 写 blob / drift）：widget 测试的假时钟不推进真实 IO，
      // 必须让事件循环跑真实时间、并反复 flush 微任务（Agents.md §5.18）。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.idle();
        await tester.pump();
      }
      await _settle(tester);

      expect(ctrl.text, contains('.bmp](sui://'),
          reason: '扩展名按字节魔数判定（BR-123.3）：${ctrl.text}');
      await db.close();
    });

    testWidgets('HTML 只有本地图片引用 → 以位图为准，不写 file://', (tester) async {
      final db = AppDatabase.memory();
      final controller = await _pumpEditor(tester, db, 'v222-file', '前');
      final ctrl = _contentValue(tester);
      _useClipboardImage(_pngBytes());
      _mockClipboard(
        tester,
        html: '<img src="file:///tmp/snipaste-123.png">',
        plain: null,
      );

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      // 附件入库是**真实 IO**（sha256 / 写 blob / drift）：widget 测试的假时钟不推进真实 IO，
      // 必须让事件循环跑真实时间、并反复 flush 微任务（Agents.md §5.18）。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.idle();
        await tester.pump();
      }
      await _settle(tester);

      expect(ctrl.text.contains('file://'), isFalse,
          reason: '绝不按路径读本地文件、也不写坏引用（§28.4）');
      expect(ctrl.text, contains('](sui://'));
      expect(controller.attachments, hasLength(1));
      await db.close();
    });

    testWidgets('HTML 只有远端图片 → 保留原地址、不新增附件', (tester) async {
      final db = AppDatabase.memory();
      final controller = await _pumpEditor(tester, db, 'v222-remote', '前');
      final ctrl = _contentValue(tester);
      _useClipboardImage(_pngBytes());
      _mockClipboard(
        tester,
        html: '<img src="https://example.com/a.png">',
        plain: null,
      );

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      // 附件入库是**真实 IO**（sha256 / 写 blob / drift）：widget 测试的假时钟不推进真实 IO，
      // 必须让事件循环跑真实时间、并反复 flush 微任务（Agents.md §5.18）。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.idle();
        await tester.pump();
      }
      await _settle(tester);

      expect(ctrl.text, contains('https://example.com/a.png'),
          reason: '远端图片保留绝对地址（FR-27 口径不变）');
      expect(ctrl.text.contains('sui://'), isFalse);
      expect(controller.attachments, isEmpty);
      await db.close();
    });

    testWidgets('文本优先：文本 + 位图 → 只落文本、不插图', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v222-text', '前');
      final ctrl = _contentValue(tester);
      _useClipboardImage(_pngBytes());
      _mockClipboard(tester, plain: '纯文本');

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      // 附件入库是**真实 IO**（sha256 / 写 blob / drift）：widget 测试的假时钟不推进真实 IO，
      // 必须让事件循环跑真实时间、并反复 flush 微任务（Agents.md §5.18）。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.idle();
        await tester.pump();
      }
      await _settle(tester);

      expect(ctrl.text, '前纯文本');
      expect(ctrl.text.contains('![截图'), isFalse);
      await db.close();
    });

    testWidgets('纯文本粘贴（Ctrl+Shift+V）不读位图', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v222-shift', '前');
      final ctrl = _contentValue(tester);
      _useClipboardImage(_pngBytes());
      _mockClipboard(tester);

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV, shift: true);
      await tester.pump();
      await tester.pump();
      await _settle(tester);

      expect(ctrl.text, '前', reason: 'Ctrl+Shift+V 只处理文本（BR-123 / AC-718）');
      await db.close();
    });

    testWidgets('源码态：粘贴截图插入同样的附件引用', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v222-src', '前');
      final ctrl = _contentValue(tester);
      _useClipboardImage(_pngBytes());
      _mockClipboard(tester);

      await _switchMode(tester, '源码');
      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      // 附件入库是**真实 IO**（sha256 / 写 blob / drift）：widget 测试的假时钟不推进真实 IO，
      // 必须让事件循环跑真实时间、并反复 flush 微任务（Agents.md §5.18）。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.idle();
        await tester.pump();
      }
      await _settle(tester);

      expect(RegExp(r'!\[截图-[^\]]+\.png\]\(sui://[0-9a-f]{64}\)')
          .hasMatch(ctrl.text), isTrue,
          reason: '源码态所见即正本（AC-719）：${ctrl.text}');
      await db.close();
    });

    testWidgets('粘贴截图一次可撤销', (tester) async {
      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v222-undo', '前\n后');
      final ctrl = _contentValue(tester);
      _useClipboardImage(_pngBytes());
      _mockClipboard(tester);

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      // UndoHistory 入栈有 500ms 节流：先让「粘贴前」入栈（同 v0.22.1 用例）。
      await tester.pump(const Duration(milliseconds: 600));

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      // 附件入库是**真实 IO**（sha256 / 写 blob / drift）：widget 测试的假时钟不推进真实 IO，
      // 必须让事件循环跑真实时间、并反复 flush 微任务（Agents.md §5.18）。
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.idle();
        await tester.pump();
      }
      await _settle(tester);
      expect(ctrl.text, contains('sui://'));

      await tester.pump(const Duration(milliseconds: 600));
      tester.widget<TextField>(_contentField()).undoController!.undo();
      await tester.pump();
      expect(ctrl.text, '前\n后', reason: '一次撤销回到粘贴前（AC-721）');
      await db.close();
    });
  });
}
