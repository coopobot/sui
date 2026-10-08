/// 格式模式「所见即预览」与格式单元原子化（M9 缺陷修复）
/// （editor-formatting.md §13 / BR-23.7\~BR-23.9 / BR-44.11 / AC-172\~AC-176）。
///
/// - `SyntaxMarkerScan`：记号扫描口径——行级前缀 / 行内成对记号区间、围栏与表格内部不扫描、
///   缩进越界不建立前缀记号、落单记号不识别（与「预览」同源判定）。
/// - `MarkerAtomicDelete`：删除键命中记号时**一次取消整处格式**且内容逐字保留；空前缀行等价
///   「退出列表」；选区删除不留残缺记号。
/// - `TableNeverRevert`：勾选框 / 列表行紧贴表格时，删除**只取消该行记号**，表格逐字不变、仍良构；
///   无法安全合并时吞掉按键；`Backspace` 落在表格下方默认空行行首仍整块删除整表（BR-44.6 不回归）。
/// - `IndentClamp`：缩进只产出 GFM 合法结构（不把列表 / 勾选框行推成缩进代码块）。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// 取记号区间（`起始-结束` 字符串），便于断言。
List<String> _ranges(List<SyntaxMarker> markers) =>
    markers.map((m) => '${m.start}-${m.end}').toList();

void main() {
  group('SyntaxMarkerScan（记号扫描 / §13.2 / BR-23.7 / AC-172）', () {
    test('行级前缀：标题 / 无序 / 有序 / 任务 / 引用 / 分割线', () {
      const src = '# 标题\n- 项\n1. 项\n- [ ] 任务\n> 引用';
      final markers = EditorFormat.syntaxMarkers(src);
      expect(
        markers.map((m) => m.kind).toList(),
        [
          SyntaxMarkerKind.heading,
          SyntaxMarkerKind.bullet,
          SyntaxMarkerKind.ordered,
          SyntaxMarkerKind.task,
          SyntaxMarkerKind.quote,
        ],
      );
      expect(_ranges(markers), ['0-2', '5-7', '9-12', '14-20', '23-25']);
      expect(markers[2].displayNumber, 1, reason: '有序列表显示编号（FR-48 惰性编号）');
      expect(markers[3].checked, isFalse);
    });

    test('行内成对记号：开闭两侧各一个记号、同 pairId', () {
      final markers = EditorFormat.syntaxMarkers('**粗** 与 ==高==');
      expect(_ranges(markers), ['0-2', '3-5', '8-10', '11-13']);
      expect(markers[0].kind, SyntaxMarkerKind.strong);
      expect(markers[0].pairId, markers[1].pairId);
      expect(markers[2].kind, SyntaxMarkerKind.highlight);
      expect(markers[2].pairId, markers[3].pairId);
      expect(markers[0].pairId, isNot(markers[2].pairId));
    });

    test('行内代码 / 链接语法部分同样成对', () {
      final code = EditorFormat.syntaxMarkers('`码`');
      expect(_ranges(code), ['0-1', '2-3']);
      final link = EditorFormat.syntaxMarkers('[标签](https://e.com)');
      expect(_ranges(link), ['0-1', '3-19']);
      expect(link.first.kind, SyntaxMarkerKind.link);
    });

    test('围栏代码块内部不扫描', () {
      final markers = EditorFormat.syntaxMarkers('```\n# 伪标题 **伪粗**\n```');
      expect(
        markers.map((m) => m.kind).toList(),
        [SyntaxMarkerKind.fence, SyntaxMarkerKind.fence],
        reason: '围栏行本身是记号，围栏内部按预览口径不解析 Markdown',
      );
      expect(_ranges(markers), ['0-3', '17-20']);
      expect(markers.first.pairId, markers.last.pairId, reason: '配对围栏同生共死');
    });

    test('良构表格块内部不扫描（整表由表格呈现单元承担）', () {
      final markers = EditorFormat.syntaxMarkers('| **A** | B |\n| --- | --- |');
      expect(markers, isEmpty);
    });

    test('缩进越界的列表行不建立前缀记号（与预览的代码块判定一致）', () {
      expect(EditorFormat.isListLineAt('  - [ ] a', 0), isTrue,
          reason: '2 空格缩进仍解析为任务项');
      expect(EditorFormat.isListLineAt('    - [ ] a', 0), isFalse,
          reason: '4 空格缩进被 GFM 解析为缩进代码块');
      expect(EditorFormat.syntaxMarkers('    - [ ] a'), isEmpty,
          reason: '两态行级结构判定一致：不画勾选框');
    });

    test('有父列表项时缩进层级合法（可嵌套）', () {
      expect(EditorFormat.isListLineAt('- x\n    - [ ] a', 4), isTrue);
      expect(EditorFormat.isListLineAt('- x\n      - [ ] a', 4), isFalse,
          reason: '父项缩进 0 + 标记宽度 2 + 3 → 上限 4');
      expect(EditorFormat.isListLineAt('- x\n  - [ ] a\n    - [ ] b', 14), isTrue,
          reason: '父项缩进 2 → 上限 7，4 空格合法');
    });

    test('上一非空行是普通段落 → 只能是顶层列表项', () {
      expect(EditorFormat.isListLineAt('段落\n    - [ ] a', 3), isFalse);
      expect(EditorFormat.isListLineAt('段落\n\n    - [ ] a', 4), isFalse);
    });

    test('落单 / 未识别记号不进集合（预览同样只是原文）', () {
      expect(EditorFormat.syntaxMarkers('**abc'), isEmpty);
      expect(EditorFormat.syntaxMarkers('-[ ] x'), isEmpty,
          reason: '`-` 后无空白不成列表标记');
      expect(EditorFormat.syntaxMarkers('==未成对'), isEmpty);
      expect(
        EditorFormat.syntaxMarkers('- [ 未闭合').map((m) => m.kind),
        [SyntaxMarkerKind.bullet],
        reason: '`- [ 未闭合` 是普通无序列表项（预览同样只呈现项目符号）',
      );
    });

    test('分割线行：上一行是普通段落时为 setext 标题下划线（隐藏下划线、上一行按标题呈现）', () {
      expect(
        EditorFormat.syntaxMarkers('标题\n---').map((m) => m.kind),
        [SyntaxMarkerKind.setext],
        reason: 'GFM 视为 setext 标题；下划线仍是「不可见的语法字符」，故照样隐藏',
      );
      expect(EditorFormat.isSetextUnderlineAt('标题\n---', 3), isTrue);
      expect(EditorFormat.isSetextUnderlineAt('标题\n\n---', 4), isFalse);
      expect(
        EditorFormat.syntaxMarkers('标题\n\n---').map((m) => m.kind),
        [SyntaxMarkerKind.rule],
        reason: '空行之后才是真正的分割线',
      );
    });

    test('单元格内联记号扫描不含行级前缀', () {
      final markers = EditorFormat.inlineSyntaxMarkers('**粗** - [ ] x');
      expect(_ranges(markers), ['0-2', '3-5']);
    });
  });

  group('MarkerAtomicDelete（记号原子删除 / §13.2 / BR-23.8 / AC-173 / AC-174）', () {
    test('退格命中成对记号闭合侧 → 去掉整对、内容逐字保留', () {
      const src = '**粗**';
      final r = EditorFormat.structuralDelete(src, src.length, src.length,
          backspace: true)!;
      expect(r.text, '粗', reason: '不得留下 `**粗` 一类残缺记号');
    });

    test('Delete 命中成对记号起始侧 → 同样去掉整对', () {
      const src = '==高==';
      final r = EditorFormat.structuralDelete(src, 0, 0, backspace: false)!;
      expect(r.text, '高');
    });

    test('内容多于一个字符时，内容侧删除不改记号（交默认逐字符删除）', () {
      const src = '**粗细**';
      final r = EditorFormat.structuralDelete(src, 4, 4, backspace: true);
      expect(r, isNull, reason: '目标是内容字符 `细`，不是记号');
    });

    test('删除成对记号仅剩的最后一个内容字符 → 连整对一并移除（不留空对）', () {
      const src = '**粗**';
      final r = EditorFormat.structuralDelete(src, 3, 3, backspace: true)!;
      expect(r.text, '');
    });

    test('行级前缀：退格落在内容起点 → 去掉整行前缀、内容保留', () {
      const task = '- [ ] 任务';
      expect(
        EditorFormat.structuralDelete(task, 6, 6, backspace: true)!.text,
        '任务',
      );
      expect(
        EditorFormat.structuralDelete('## 标题', 3, 3, backspace: true)!.text,
        '标题',
      );
      expect(
        EditorFormat.structuralDelete('- 项', 2, 2, backspace: true)!.text,
        '项',
      );
      expect(
        EditorFormat.structuralDelete('> 引用', 2, 2, backspace: true)!.text,
        '引用',
      );
      expect(
        EditorFormat.structuralDelete('1. 项', 3, 3, backspace: true)!.text,
        '项',
      );
    });

    test('空前缀行：行首退格 / 行尾删除均整块移除前缀（等价「退出列表」）', () {
      const src = '- [ ] ';
      expect(EditorFormat.structuralDelete(src, 0, 0, backspace: true)!.text, '');
      expect(EditorFormat.structuralDelete(src, 6, 6, backspace: true)!.text, '');
      expect(EditorFormat.structuralDelete(src, 6, 6, backspace: false)!.text, '');
    });

    test('围栏代码块：命中围栏行 → 连行移除、内容保留', () {
      const src = '```\ncode\n```';
      final r = EditorFormat.structuralDelete(src, 3, 3, backspace: true)!;
      expect(r.text, 'code');
    });

    test('分割线：命中 → 连行移除', () {
      const src = '甲\n\n---\n\n乙';
      final r = EditorFormat.structuralDelete(src, 6, 6, backspace: true)!;
      expect(r.text.contains('---'), isFalse);
      expect(r.text.contains('甲'), isTrue);
      expect(r.text.contains('乙'), isTrue);
    });

    test('选区删除：命中成对记号任一侧 → 按整对处理（内容保留）', () {
      const src = '前**粗**后';
      final r = EditorFormat.structuralDelete(src, 1, 3, backspace: true)!;
      expect(r.text, '前粗后');
    });

    test('选区覆盖成对记号全部内容 → 连记号一并移除（不留空对）', () {
      const src = '前**粗**后';
      final r = EditorFormat.structuralDelete(src, 3, 4, backspace: true)!;
      expect(r.text, '前后');
    });

    test('选区不涉及任何记号 / 单元 → 交默认删除', () {
      const src = '普通文字';
      expect(EditorFormat.structuralDelete(src, 1, 3, backspace: true), isNull);
    });

    test('源码模式不原子化：调用方只在格式模式走本入口（口径由 UI 层保证）', () {
      // 本入口是纯函数；「仅在格式模式生效」由 note_editor 的 _handleStructuralDelete 把关。
      expect(EditorFormat.structuralDelete('**粗**', 5, 5, backspace: true)!.text,
          '粗');
    });
  });

  group('TableNeverRevert（表格永不「打回原形」/ §13.4 / BR-44.11 / AC-175）', () {
    const table = '| A | B |\n| --- | --- |\n| 1 | 2 |';

    test('勾选框紧贴表格上方：退格命中 `- [ ] ` → 只取消前缀，表格逐字不变', () {
      const src = '- [ ] \n$table';
      final caret = '- [ ] '.length;
      final r = EditorFormat.structuralDelete(src, caret, caret,
          backspace: true)!;
      expect(r.text, '\n$table');
      final t = EditorFormat.parseTable(r.text, 1)!;
      expect(t.wellFormed, isTrue, reason: '表格仍良构（未被打回原形）');
    });

    test('Delete 停在紧贴表格的勾选框行行尾 → 取消前缀，表格逐字不变', () {
      const src = '- [ ] \n$table';
      final r = EditorFormat.structuralDelete(src, 6, 6, backspace: false)!;
      expect(r.text, '\n$table');
    });

    test('Delete 停在紧贴表格的非空前缀行行尾 → 吞掉按键（正本与光标均不变）', () {
      const src = '- [ ] x\n$table';
      final caret = '- [ ] x'.length;
      final r = EditorFormat.structuralDelete(src, caret, caret,
          backspace: false)!;
      expect(r.text, src, reason: '绝不把 `- [ ] x` 并进表头行');
      expect(r.selectionStart, caret);
    });

    test('相邻行是普通文字（无可取消记号）→ 吞掉按键', () {
      const src = '前文\n$table';
      final r = EditorFormat.structuralDelete(src, 2, 2, backspace: false)!;
      expect(r.text, src);
    });

    test('相邻行是空行 → 允许默认合并（返回 null，表格行字节不变）', () {
      const src = '前文\n\n$table';
      final pos = '前文\n'.length;
      expect(EditorFormat.structuralDelete(src, pos, pos, backspace: false),
          isNull);
    });

    test('退格落在表格下方默认空行行首 → 仍整块删除整张表格（BR-44.6 不回归）', () {
      const src = '前文\n$table\n后文';
      final pos = '前文\n'.length + table.length;
      final r = EditorFormat.structuralDelete(src, pos, pos,
          backspace: true)!;
      expect(r.text, '前文\n后文');
    });

    test('选区跨过表格 → 整块删除表格，不留半张表', () {
      const src = '前文\n$table\n后文';
      final r = EditorFormat.structuralDelete(src, 2, 5, backspace: false)!;
      expect(r.text.contains('| --- |'), isFalse, reason: '不得留下残缺表结构');
    });
  });

  group('IndentClamp（缩进只产出 GFM 合法结构 / §13.3 / BR-23.9 / AC-176）', () {
    test('孤立勾选框行只能缩进一次（绝不产出 4 空格缩进）', () {
      final r1 = EditorFormat.apply(FormatCommand.indent, '- [ ] a', 0, 0);
      expect(r1.text, '  - [ ] a');
      final r2 = EditorFormat.apply(FormatCommand.indent, r1.text, 0, 0);
      expect(r2.text, '  - [ ] a', reason: '已在最深合法层级 → 原样不动');
      expect(EditorFormat.isListLineAt(r2.text, 0), isTrue);
    });

    test('有父列表项时可缩进成嵌套', () {
      const src = '- x\n- [ ] a';
      final r = EditorFormat.apply(FormatCommand.indent, src, 4, 4);
      expect(r.text, '- x\n  - [ ] a');
      expect(EditorFormat.isListLineAt(r.text, 4), isTrue);
    });

    test('非列表（段落）行最多缩进到 2 个空格（≥4 会变缩进代码块）', () {
      var text = '段落';
      for (var i = 0; i < 4; i++) {
        text = EditorFormat.apply(FormatCommand.indent, text, 0, 0).text;
      }
      expect(text, '  段落');
    });

    test('反缩进可还原缩进', () {
      const src = '  - [ ] a';
      final r = EditorFormat.apply(FormatCommand.outdent, src, 2, 2);
      expect(r.text, '- [ ] a');
    });

    test('紧贴表格的勾选框行缩进：不把表格行卷入（逐行处理）', () {
      const src = '- [ ] a\n| A | B |\n| --- | --- |';
      final r = EditorFormat.apply(FormatCommand.indent, src, 0, 0);
      expect(r.text, '  - [ ] a\n| A | B |\n| --- | --- |');
    });
  });
}
