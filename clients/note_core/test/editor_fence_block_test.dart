/// M15 单测：围栏代码块的整体化与边界保护（FR-81 / BR-81.2~81.5）。
///
/// **红检**（回退源文件再跑本文件）：`fenceBlocks` / `fenceBlockForDeletion` /
/// `deleteFenceBlock` 尚不存在 → 编译失败；若只回退 `structuralDelete` 的接线，则
/// 「首内容行行首 Backspace」会走旧的「围栏记号成对移除」语义、把首行代码吞进围栏行 →
/// 整块删除类用例失败。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('FenceBlocks（区间扫描，FR-81）', () {
    test('LF 单块：八个字段完整', () {
      const src = '```\ncode\n```';
      final b = EditorFormat.fenceBlocks(src).single;
      expect(b.start, 0);
      expect(b.openLineEnd, 3);
      expect(b.contentStart, 4);
      expect(b.contentEnd, 9);
      expect(b.closeLineStart, 9);
      expect(b.closeLineEnd, 12);
      expect(b.closed, isTrue);
      expect(b.end, 12);
    });

    test('CRLF 单块：行尾 \\r 不影响识别', () {
      const src = '```\r\ncode\r\n```';
      final b = EditorFormat.fenceBlocks(src).single;
      expect(b.start, 0);
      expect(b.openLineEnd, 4, reason: '行尾 `\\r` 属本行字节');
      expect(b.contentStart, 5);
      expect(b.contentEnd, 11);
      expect(b.closeLineStart, 11);
      expect(b.closed, isTrue);
      expect(b.end, 14);
    });

    test('未闭合：吃到文末，closed=false', () {
      const src = '甲\n```\ncode';
      final b = EditorFormat.fenceBlocks(src).single;
      expect(b.start, 2);
      expect(b.openLineEnd, 5);
      expect(b.contentStart, 6);
      expect(b.contentEnd, 10);
      expect(b.closeLineStart, 10);
      expect(b.closeLineEnd, 10);
      expect(b.closed, isFalse);
      expect(b.end, 10);
    });

    test('多块：按出现顺序，tilde 围栏同样识别', () {
      const src = '```\na\n```\n\n正文\n\n~~~\nb\n~~~';
      final bs = EditorFormat.fenceBlocks(src);
      expect(bs, hasLength(2));
      expect(src.substring(bs[0].start, bs[0].contentStart), '```\n');
      expect(src.substring(bs[1].start, bs[1].contentStart), '~~~\n');
      expect(bs[0].closed, isTrue);
      expect(bs[1].closed, isTrue);
      expect(bs[0].end, lessThan(bs[1].start));
    });

    test('空内容块：contentStart == contentEnd', () {
      const src = '```\n```';
      final b = EditorFormat.fenceBlocks(src).single;
      expect(b.contentStart, 4);
      expect(b.contentEnd, 4);
      expect(b.closed, isTrue);
    });

    test('块内更短围栏：与 syntaxMarkers 同源口径——内容行以 ``` 开头即闭合', () {
      // `_fencePrefixRe` 只认「以 ``` / ~~~ 开头」，**不校验长度**（与记号扫描同源）。
      // 本用例锁定这一已知口径（未做「围栏长度须不短于开围栏」的增强）。
      const src = '````\n```\n````';
      final bs = EditorFormat.fenceBlocks(src);
      expect(bs, hasLength(2));
      expect(bs[0].contentEnd, 5);
    });

    test('围栏行在良构表格块内不参与翻转（与记号扫描一致）', () {
      const src = '| A |\n| --- |\n| ``` |';
      expect(EditorFormat.fenceBlocks(src), isEmpty);
    });

    test('fenceBlockAt：围栏行 / 内容 / 块末那一格都命中，块外为 null', () {
      const src = '甲\n```\ncode\n```\n乙';
      expect(EditorFormat.fenceBlockAt(src, 2), isNotNull);
      expect(EditorFormat.fenceBlockAt(src, 7), isNotNull);
      expect(EditorFormat.fenceBlockAt(src, 0), isNull);
      expect(EditorFormat.fenceBlockAt(src, 15), isNull);
    });
  });

  group('FenceBlockDelete（边界不可破，FR-81 / BR-81.4）', () {
    const src = '前\n```\ncode\n```\n后';

    test('首内容行行首 Backspace → 整块删除（改动前把首行代码吞进围栏行）', () {
      final r = EditorFormat.structuralDelete(src, 6, 6, backspace: true)!;
      expect(r.text, '前\n后');
      expect(r.text.contains('code'), isFalse);
      expect(r.text.contains('```'), isFalse);
    });

    test('末内容行行尾 Delete → 整块删除（改动前吃掉闭合围栏）', () {
      final r = EditorFormat.structuralDelete(src, 10, 10, backspace: false)!;
      expect(r.text, '前\n后');
      expect(r.text.contains('```'), isFalse);
    });

    test('围栏行行首 Backspace / 行尾 Delete → 整块删除', () {
      expect(
        EditorFormat.structuralDelete(src, 2, 2, backspace: true)!.text,
        '前\n后',
      );
      expect(
        EditorFormat.structuralDelete(src, 4, 4, backspace: false)!.text,
        '前\n后',
      );
    });

    test('块下方行首 Backspace / Delete → 整块删除', () {
      expect(
        EditorFormat.structuralDelete(src, 15, 15, backspace: true)!.text,
        '前\n后',
      );
      expect(
        EditorFormat.structuralDelete(src, 15, 15, backspace: false)!.text,
        '前\n后',
      );
    });

    test('块内**中间**代码行：普通合并，不整块删除（BR-81.3）', () {
      const multi = '```\na\nb\n```';
      // 中间行 `a` 行尾 Delete → 交默认逐字符删除（返回 null）。
      expect(EditorFormat.structuralDelete(multi, 5, 5, backspace: false),
          isNull);
      // 中间行 `b` 行首 Backspace → 同样交默认。
      expect(EditorFormat.structuralDelete(multi, 6, 6, backspace: true), isNull);
    });

    test('块内内容仍可编辑：光标在代码中间不触发整块删除', () {
      expect(EditorFormat.structuralDelete(src, 8, 8, backspace: true), isNull);
      expect(EditorFormat.structuralDelete(src, 8, 8, backspace: false), isNull);
    });

    test('选中内容的一部分删除 → 普通删除（不整块删除）', () {
      expect(EditorFormat.structuralDelete(src, 7, 9, backspace: true), isNull);
    });

    test('选中围栏行删除 → 整块删除', () {
      final r = EditorFormat.structuralDelete(src, 2, 5, backspace: true)!;
      expect(r.text, '前\n后');
    });

    test('删除后不留 ≥3 连续换行（块上下本就各有一个空行）', () {
      const blank = '甲\n\n```\nc\n```\n\n乙';
      final r = EditorFormat.structuralDelete(blank, 7, 7, backspace: true)!;
      expect(r.text, '甲\n\n乙');
      expect(r.text.contains('\n\n\n'), isFalse);
    });

    test('未闭合块：首内容行行首 Backspace → 连到文末整块删除', () {
      const open = '甲\n```\ncode\nmore';
      final r = EditorFormat.structuralDelete(open, 6, 6, backspace: true)!;
      expect(r.text, '甲');
    });

    test('围栏行文档末尾：删前导换行、不残留空行', () {
      const tail = '前\n```\ncode\n```';
      final r = EditorFormat.structuralDelete(tail, 6, 6, backspace: true)!;
      expect(r.text, '前');
    });

    test('正本字节不变：块内代码逐字可往返（不整块删除路径）', () {
      const src2 = '```\ncode\n```';
      // 光标在代码中间 → 本层不介入，正本由调用方按默认删除处理。
      expect(EditorFormat.structuralDelete(src2, 5, 5, backspace: false), isNull);
    });
  });
}
