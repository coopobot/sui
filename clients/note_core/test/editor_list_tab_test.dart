/// M18 / FR-108：列表 `Tab` 缩进、`Shift+Tab` 反缩进与 `-` + `Tab` 自动成列表
/// （`EditorFormat.tabListIndent`）。
///
/// 契约（editor-context-menu.md §3 / ADR-038）：
/// * 返回 `null` = **不适用**（非列表行 / 混合选区），调用方必须把 `Tab` 交还默认焦点移动；
/// * 返回结果 = 已处理；**文本未变**（已到合法上限 / 顶层反缩进）也返回非 null，按键被消费；
/// * 缩进单位恒为 2 空格，受 `_listIndentLimit`（BR-23.9）约束；
/// * 光标按所在行的缩进增量平移，不跳文末、不整段选中。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('TabAutoList（`-` + `Tab` 自动成列表）', () {
    test('裸 `-` → `- `，光标落在标记之后', () {
      final r = EditorFormat.tabListIndent('-', 1, 1, outdent: false);
      expect(r, isNotNull);
      expect(r!.text, '- ');
      expect(r.selectionStart, 2);
      expect(r.selectionEnd, 2);
    });

    test('`*` / `+` 同口径', () {
      expect(EditorFormat.tabListIndent('*', 1, 1, outdent: false)!.text, '* ');
      expect(EditorFormat.tabListIndent('+', 1, 1, outdent: false)!.text, '+ ');
    });

    test('格式模式的转义形态 `\\-` / `\\*` / `\\+` 还原为真列表标记', () {
      // 格式模式的 MarkdownSyntaxEscapeFormatter 会把行首 `-`/`+` 与任意位置的 `*`
      // 落成转义形态（ADR-029）；自动成列表必须识别它，否则「键入 - 再按 Tab 没反应」。
      final minus = EditorFormat.tabListIndent(r'\-', 2, 2, outdent: false)!;
      expect(minus.text, '- ');
      expect(minus.selectionStart, 2);

      final star = EditorFormat.tabListIndent(r'\*', 2, 2, outdent: false)!;
      expect(star.text, '* ');

      final plus = EditorFormat.tabListIndent(r'\+', 2, 2, outdent: false)!;
      expect(plus.text, '+ ');
    });

    test('保留行首空白', () {
      final r = EditorFormat.tabListIndent('  -', 3, 3, outdent: false)!;
      expect(r.text, '  - ');
      expect(r.selectionStart, 4);
    });

    test('非行首的 `-`（如 `1 - 2`）不触发，返回 null', () {
      expect(EditorFormat.tabListIndent('1 - 2', 5, 5, outdent: false), isNull);
    });

    test('有选区（非折叠）不触发自动成列表', () {
      expect(EditorFormat.tabListIndent('-', 0, 1, outdent: false), isNull);
    });

    test('反缩进不触发自动成列表（裸标记不是列表行）', () {
      expect(EditorFormat.tabListIndent('-', 1, 1, outdent: true), isNull);
    });

    test('`- `（已带空格）不算裸标记，按空列表项缩进', () {
      final r = EditorFormat.tabListIndent('- ', 2, 2, outdent: false)!;
      expect(r.text, '  - ');
      expect(r.selectionStart, 4);
    });

    test('行内已有文字时只按列表项缩进', () {
      final r = EditorFormat.tabListIndent('- 项', 3, 3, outdent: false)!;
      expect(r.text, '  - 项');
      expect(r.selectionStart, 5);
    });
  });

  group('TabListIndent（缩进 / 反缩进）', () {
    test('无序列表缩进 2 空格，光标随行平移', () {
      final r = EditorFormat.tabListIndent('- a', 3, 3, outdent: false)!;
      expect(r.text, '  - a');
      expect(r.selectionStart, 5);
      expect(r.selectionEnd, 5);
    });

    test('有序列表与任务列表同口径', () {
      final ordered = EditorFormat.tabListIndent('1. a', 4, 4, outdent: false)!;
      expect(ordered.text, '  1. a');
      expect(ordered.selectionStart, 6);

      final task =
          EditorFormat.tabListIndent('- [ ] a', 7, 7, outdent: false)!;
      expect(task.text, '  - [ ] a');
      expect(task.selectionStart, 9);
    });

    test('反缩进去掉 2 个行首空格', () {
      final r = EditorFormat.tabListIndent('  - a', 5, 5, outdent: true)!;
      expect(r.text, '- a');
      expect(r.selectionStart, 3);
    });

    test('反缩进去掉 1 个行首 Tab', () {
      final r = EditorFormat.tabListIndent('\t- a', 4, 4, outdent: true)!;
      expect(r.text, '- a');
      expect(r.selectionStart, 3);
    });

    test('顶层反缩进：文本不变但返回结果（按键被消费）', () {
      final r = EditorFormat.tabListIndent('- a', 3, 3, outdent: true);
      expect(r, isNotNull);
      expect(r!.text, '- a');
      expect(r.selectionStart, 3);
      expect(r.selectionEnd, 3);
    });

    test('到达合法层级上限后不再缩进，文本不变', () {
      // 上一非空行是普通段落 → 该列表行的合法上限 = 3（BR-23.9）。
      const src = '段落\n\n- a';
      final once =
          EditorFormat.tabListIndent(src, src.length, src.length, outdent: false)!;
      expect(once.text, '段落\n\n  - a');
      final twice = EditorFormat.tabListIndent(
          once.text, once.selectionStart, once.selectionEnd,
          outdent: false)!;
      expect(twice.text, once.text, reason: '4 空格会变成缩进代码块');
      expect(twice.selectionStart, once.selectionStart);
    });

    test('光标落在行首空白内时钳制到行首', () {
      final r = EditorFormat.tabListIndent('  - a', 1, 1, outdent: true)!;
      expect(r.text, '- a');
      expect(r.selectionStart, 0);
    });

    test('多行选区整体缩进，行内容逐字不动', () {
      const src = '- a\n- b';
      final r = EditorFormat.tabListIndent(src, 0, src.length, outdent: false)!;
      expect(r.text, '  - a\n  - b');
      expect(r.selectionStart, 2);
      expect(r.selectionEnd, 11);
    });

    test('多行选区含空行：空行原样保留', () {
      const src = '- a\n\n- b';
      final r = EditorFormat.tabListIndent(src, 0, src.length, outdent: false)!;
      expect(r.text, '  - a\n\n  - b');
    });

    test('选区含非列表行：整体不处理（返回 null）', () {
      const src = '- a\n段落';
      expect(
          EditorFormat.tabListIndent(src, 0, src.length, outdent: false), isNull);
    });

    test('普通段落 / 标题 / 代码块行返回 null（Tab 交还焦点移动）', () {
      for (final line in ['段落', '# 标题', '> 引用', '```', '    code']) {
        expect(EditorFormat.tabListIndent(line, line.length, line.length,
            outdent: false),
            isNull,
            reason: '「$line」不是列表行');
      }
    });

    test('缩进结果在格式判定里仍是合法列表行', () {
      const src = '- a';
      var text = src;
      var caret = src.length;
      // 连续缩进到上限：每一步都必须仍是合法列表行。
      for (var i = 0; i < 3; i++) {
        final r = EditorFormat.tabListIndent(text, caret, caret, outdent: false)!;
        text = r.text;
        caret = r.selectionStart;
        expect(EditorFormat.isListLineAt(text, 0), isTrue,
            reason: '第 ${i + 1} 次缩进后「$text」应仍是合法列表行');
      }
    });

    test('末尾换行 / 光标在文末空行时不误判', () {
      const src = '- a\n';
      final r = EditorFormat.tabListIndent(src, src.length, src.length,
          outdent: false);
      expect(r, isNull, reason: '末行是空行，不属于任何列表项');
    });
  });
}
