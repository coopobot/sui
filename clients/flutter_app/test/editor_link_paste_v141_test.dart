/// 优化补丁 `v0.14.1`：**笔记内链接可点击**（FR-70）与**剪贴板富文本粘贴**（FR-71）。
///
/// 覆盖：
/// * `CfHtml`——Windows CF_HTML 字节流的片段解析（字节偏移 / 兜底 / 异常输入）；
/// * `UrlSchemeWhitelist`——协议白名单（只有 http/https/mailto/tel 可打开）；
/// * `PreviewLinkTap`——预览态点链接即交系统浏览器打开（此前未传 `onTapLink`，点了没反应）；
/// * `EditorLinkBar`——格式模式光标落在链接里时出现链接条，「打开」按钮接线正确；
/// * `PasteRichText`——剪贴板 HTML（原生通道）经 DOM 式转换器落成 Markdown。
///
/// 纪律：全组**禁用** `pumpAndSettle()`（Agents.md §5.2），一律有界 `pump`。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/platform/cf_html.dart';
import 'package:sui_flutter_app/src/platform/url_opener.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

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

  await tester.binding.setSurfaceSize(const Size(1200, 800));
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

/// 装上平台剪贴板 mock：测试环境下不装时 `Clipboard.getData` 不会返回，
/// 会让粘贴链路停在读纯文本这一步（生产由嵌入层实现，不受影响）。
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
}

/// 造一段 CF_HTML：头部 ASCII（偏移为**字节**偏移），随后是 UTF-8 正文。
Uint8List _cfHtml(String body, {bool withHeader = true}) {
  String header(int start, int end) => 'Version:0.9\r\n'
      'StartHTML:0000000000\r\n'
      'StartFragment:${start.toString().padLeft(10, '0')}\r\n'
      'EndFragment:${end.toString().padLeft(10, '0')}\r\n\r\n';
  if (!withHeader) return Uint8List.fromList(utf8.encode(body));
  final probe = utf8.encode(header(0, 0)).length;
  final start = probe + body.indexOf('<b>');
  final end = probe + body.indexOf('</b>') + 4;
  return Uint8List.fromList(utf8.encode(header(start, end) + body));
}

void main() {
  group('CfHtml（Windows CF_HTML 片段解析 / FR-71 / §17.2）', () {
    test('按 StartFragment / EndFragment 取片段', () {
      final data = _cfHtml('<html><body><b>bold</b>tail</body></html>');
      expect(decodeCfHtml(data), '<b>bold</b>');
    });

    test('无头部（应用直接写 HTML 片段）→ 整体按 UTF-8 解码', () {
      final data = _cfHtml('<b>片段</b>', withHeader: false);
      expect(decodeCfHtml(data), '<b>片段</b>');
    });

    test('偏移非法 / 越界 → 不抛异常，退回整体解码', () {
      final bad = Uint8List.fromList(
        utf8.encode('StartFragment:9999\r\nEndFragment:1\r\n<p>x</p>'),
      );
      expect(decodeCfHtml(bad), contains('<p>x</p>'));
    });

    test('空输入返回 null（调用方回落纯文本）', () {
      expect(decodeCfHtml(const <int>[]), isNull);
    });
  });

  group('UrlSchemeWhitelist（协议白名单 / BR-70.2）', () {
    test('http / https / mailto / tel 可打开', () {
      expect(isOpenableUrl('http://a.com'), isTrue);
      expect(isOpenableUrl('https://a.com/x?y=1'), isTrue);
      expect(isOpenableUrl('mailto:a@b.com'), isTrue);
      expect(isOpenableUrl('tel:12345'), isTrue);
    });

    test('危险协议与缺主机一律拒绝', () {
      expect(isOpenableUrl('javascript:alert(1)'), isFalse);
      expect(isOpenableUrl('data:text/html,<b>'), isFalse);
      expect(isOpenableUrl('file:///etc/passwd'), isFalse);
      expect(isOpenableUrl('https://'), isFalse);
      expect(isOpenableUrl('随便写的'), isFalse);
    });
  });

  group('PreviewLinkTap（预览态点链接即打开 / FR-70 / AC-349）', () {
    testWidgets('点 Markdown 链接 → 交 opener；非白名单协议不打开', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              text: '[示例](https://example.com/a) 与 [坏](javascript:alert(1))',
              linkOpener: (url) async {
                opened.add(url);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pump();

      // 真实指针点击（走 widget 手势 + 手势竞技场），而不是直接调 recognizer。
      await tester.tap(find.text('示例'));
      await tester.pump();
      expect(opened, ['https://example.com/a']);

      await tester.tap(find.text('坏'));
      await tester.pump();
      expect(opened.length, 1, reason: 'javascript: 一律不打开');
    });
  });

  group('EditorLinkBar（格式模式链接条 / FR-70 / §16.2）', () {
    testWidgets('光标落在链接内出现链接条，「打开」接线到系统浏览器', (tester) async {
      final opened = <String>[];
      debugUrlOpenerOverride = (url) async {
        opened.add(url);
        return true;
      };
      addTearDown(() => debugUrlOpenerOverride = null);

      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v141-link-bar', '看 [这里](https://a.com) 吧');

      final ctrl = _contentValue(tester);
      ctrl.selection =
          TextSelection.collapsed(offset: ctrl.text.indexOf('这里') + 1);
      await tester.pump();

      expect(find.text('https://a.com'), findsOneWidget,
          reason: '光标落在链接里应出现链接条（显示目标地址）');
      expect(find.text('打开'), findsOneWidget);

      await tester.tap(find.text('打开'));
      await tester.pump();
      expect(opened, ['https://a.com']);

      // 光标移出链接 → 链接条消失。
      ctrl.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(find.text('打开'), findsNothing);

      await db.close();
    });
  });

  group('PasteRichText（剪贴板 HTML → Markdown / FR-71 / AC-356）', () {
    testWidgets('Ctrl+V 走原生通道读 HTML，经 DOM 转换器落笔', (tester) async {
      debugClipboardHtmlOverride = () async =>
          '<ol><li>一</li><li>二</li></ol><p><b>粗</b></p>';
      addTearDown(() => debugClipboardHtmlOverride = null);

      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v141-paste-html', '前\n后');
      _mockClipboard(tester, plain: '前 后');
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final ctrl = _contentValue(tester);

      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      await tester.pump();
      await tester.pump();

      expect(ctrl.text, contains('1. 一'),
          reason: '有序列表必须作为列表落笔（旧正则版只能退化成 `- `）');
      expect(ctrl.text, contains('2. 二'));
      expect(ctrl.text, contains('**粗**'),
          reason: '剪贴板路径的加粗要落成真强调（DOM 转换器 + 字面保护）');

      await db.close();
    });

    testWidgets('Ctrl+Shift+V 恒纯文本：HTML 不参与', (tester) async {
      debugClipboardHtmlOverride = () async => '<b>不该出现</b>';
      addTearDown(() => debugClipboardHtmlOverride = null);

      final db = AppDatabase.memory();
      await _pumpEditor(tester, db, 'v141-paste-plain', '前');
      _mockClipboard(tester, html: '不该出现', plain: 'a*b_c');
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final ctrl = _contentValue(tester);

      // 纯文本来源由平台剪贴板提供；这里只断言「没有落 HTML 转换结果」。
      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      await _pressCtrl(tester, LogicalKeyboardKey.keyV, shift: true);
      await tester.pump();
      await tester.pump();

      expect(ctrl.text.contains('不该出现'), isFalse);
      expect(ctrl.text, contains(r'a\*b\_c'),
          reason: 'Ctrl+Shift+V 仍按纯文本转义插入（FR-45 口径不变）');

      await db.close();
    });
  });
}
