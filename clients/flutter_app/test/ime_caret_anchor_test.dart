import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sui_flutter_app/src/ui/ime_caret_anchor.dart';

/// v0.17.1 / FR-98 / ADR-035：Windows 中文输入法候选框跟随光标的**通道级**回归。
///
/// 断言口径（与框架自身行为对照）：
/// * 未启动锚点时，框架每帧发出的 `TextInput.setMarkedTextRect` 是**正文起点**
///   （`EditableText._updateComposingRectIfNeeded()` 在没有组合区时回退到 offset 0）；
/// * 启动锚点后，**最后一条**同名消息是**真实光标**的矩形 —— 引擎据此摆放输入法
///   组合窗口，候选框才会贴着光标。
void main() {
  /// 截获发往平台的 `flutter/textinput` 消息（这是**出站**方向：框架 → 引擎）。
  List<MethodCall> recordTextInput(WidgetTester tester) {
    final List<MethodCall> calls = <MethodCall>[];
    final TestDefaultBinaryMessenger messenger =
        tester.binding.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/textinput', (ByteData? data) async {
      if (data != null) {
        calls.add(const JSONMethodCodec().decodeMethodCall(data));
      }
      // 回一个合法空响应，避免框架把「无响应」当成 MissingPluginException 报告。
      return const JSONMethodCodec().encodeSuccessEnvelope(null);
    });
    addTearDown(
      () => messenger.setMockMessageHandler('flutter/textinput', null),
    );
    return calls;
  }

  List<MethodCall> markedTextRects(List<MethodCall> calls) => calls
      .where((MethodCall call) => call.method == 'TextInput.setMarkedTextRect')
      .toList();

  testWidgets('锚点启动后，最后一帧回填的是光标矩形而不是正文起点', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final List<MethodCall> calls = recordTextInput(tester);
      final TextEditingController controller =
          TextEditingController(text: '甲乙丙丁戊己庚辛壬癸');
      final FocusNode focusNode = FocusNode();
      addTearDown(() {
        controller.dispose();
        focusNode.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: null,
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();

      // 基线（红检口径）：此时只有框架自己的消息，矩形对应 offset 0。
      final List<MethodCall> baseline = markedTextRects(calls);
      expect(baseline, isNotEmpty, reason: '框架应当每帧发送组合矩形');
      final EditableTextState state =
          tester.state<EditableTextState>(find.byType(EditableText));
      final Rect caretRect =
          state.renderEditable.getLocalRectForCaret(const TextPosition(offset: 6));
      final Rect startRect =
          state.renderEditable.getLocalRectForCaret(const TextPosition(offset: 0));
      expect(caretRect.left - startRect.left, greaterThan(20.0),
          reason: '第 6 个字必须明显偏离正文起点，断言才有意义');
      final Map<String, dynamic> baselineArgs =
          (baseline.last.arguments as Map).cast<String, dynamic>();
      expect(baselineArgs['x'] as double, closeTo(startRect.left, 0.5),
          reason: '框架在无组合区时回退到 offset 0（本补丁存在的原因）');

      // 启动锚点：每帧回填真实光标矩形。
      ImeCaretAnchor.debugReset();
      ImeCaretAnchor.start();
      for (int i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      final List<MethodCall> after = markedTextRects(calls);
      expect(after.length, greaterThan(baseline.length),
          reason: '锚点应当额外发送组合矩形');
      final Map<String, dynamic> lastArgs =
          (after.last.arguments as Map).cast<String, dynamic>();
      expect(lastArgs['x'] as double, closeTo(caretRect.left, 0.5),
          reason: '引擎最后一次写入必须是光标矩形');
      expect(lastArgs['y'] as double, closeTo(caretRect.top, 0.5));
    } finally {
      ImeCaretAnchor.debugReset();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('光标 / 选区未变化时不再重复回填（FR-99 / BR-99.5 节流）',
      (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final TextEditingController controller =
          TextEditingController(text: '甲乙丙丁戊己庚辛壬癸');
      final FocusNode focusNode = FocusNode();
      addTearDown(() {
        controller.dispose();
        focusNode.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              focusNode: focusNode,
              maxLines: null,
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();

      ImeCaretAnchor.debugReset();
      expect(ImeCaretAnchor.debugReportCaretRect(), isTrue,
          reason: '首次回填应当发送真实光标矩形');
      expect(ImeCaretAnchor.debugReportCaretRect(), isFalse,
          reason: '光标 / 选区 / 文本 / 矩形都没变时不得重复发通道消息');

      controller.selection = const TextSelection.collapsed(offset: 6);
      expect(ImeCaretAnchor.debugReportCaretRect(), isTrue,
          reason: '光标移动后必须重新回填');
      expect(ImeCaretAnchor.debugReportCaretRect(), isFalse);
    } finally {
      ImeCaretAnchor.debugReset();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('只读输入框不回填（没有输入连接，避免引擎报无客户端）', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      recordTextInput(tester);
      final TextEditingController controller =
          TextEditingController(text: '只读内容');
      final FocusNode focusNode = FocusNode();
      addTearDown(() {
        controller.dispose();
        focusNode.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              focusNode: focusNode,
              readOnly: true,
            ),
          ),
        ),
      );
      focusNode.requestFocus();
      await tester.pump();
      ImeCaretAnchor.debugReset();
      expect(ImeCaretAnchor.debugReportCaretRect(), isFalse);
    } finally {
      ImeCaretAnchor.debugReset();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('非 Windows 平台不启用（不产生额外通道调用）', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.android,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      try {
        ImeCaretAnchor.debugReset();
        expect(ImeCaretAnchor.supported, isFalse);
        ImeCaretAnchor.start(); // 应当是 no-op
      } finally {
        ImeCaretAnchor.debugReset();
        debugDefaultTargetPlatformOverride = null;
      }
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      expect(ImeCaretAnchor.supported, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
