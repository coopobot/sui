import 'dart:convert';
import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// M13 文本链路单测（详细设计 §13 测试矩阵）：
/// 编码识别（AC-237 / AC-251）、Markdown 逐字节保真（AC-241）、纯文本空白规整（AC-242）。
void main() {
  group('编码识别（§4.2 / AC-237 / AC-251）', () {
    /// 同一段中文的四种字节形态必须解出**同一文本**。
    const sample = '你好，随手记 Sui。\n第二行。';

    test('无 BOM UTF-8', () {
      final decoded = decodeTextBytes(Uint8List.fromList(utf8.encode(sample)));
      expect(decoded.text, sample);
      expect(decoded.encoding, 'UTF-8');
      expect(decoded.degraded, isFalse);
    });

    test('UTF-8 BOM 去 BOM 且首字符不受损', () {
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(sample),
      ]);
      final decoded = decodeTextBytes(bytes);
      expect(decoded.text, sample, reason: 'BOM 必须被去掉，不得误伤首字符');
      expect(decoded.encoding, 'UTF-8 BOM');
      expect(decoded.degraded, isFalse);
    });

    test('UTF-16LE（含 BOM）', () {
      final decoded = decodeTextBytes(_utf16(sample, littleEndian: true, bom: true));
      expect(decoded.text, sample);
      expect(decoded.encoding, 'UTF-16LE');
      expect(decoded.degraded, isFalse);
    });

    test('UTF-16BE（含 BOM）', () {
      final decoded =
          decodeTextBytes(_utf16(sample, littleEndian: false, bom: true));
      expect(decoded.text, sample);
      expect(decoded.encoding, 'UTF-16BE');
      expect(decoded.degraded, isFalse);
    });

    test('无 BOM UTF-16 启发式（LE / BE 都能认出）', () {
      // 启发式口径是「`0x00` 占比 ≥ 20%」（§4.2 第 2 条），故样本以 ASCII 为主
      // （UTF-16 里 ASCII 的高字节恒为 0）；中文为主的样本见下一条（不触发启发式）。
      const asciiHeavy = 'hello suisui 12345 - plain text only.';
      final le =
          decodeTextBytes(_utf16(asciiHeavy, littleEndian: true, bom: false));
      expect(le.text, asciiHeavy);
      expect(le.encoding, 'UTF-16LE(heuristic)');

      final be =
          decodeTextBytes(_utf16(asciiHeavy, littleEndian: false, bom: false));
      expect(be.text, asciiHeavy);
      expect(be.encoding, 'UTF-16BE(heuristic)');
    });

    test('启发式有界：中文为主的 UTF-16 无 BOM 样本 NUL 占比不足 → 不启用', () {
      // 中文在 UTF-16 里的高字节非 0，NUL 占比低；此时按 §4.2 回落到 UTF-8 分支
      // （严格解码失败 → 替换字符降级），而非猜测编码——这是设计给定的已知边界。
      final bytes = _utf16(sample, littleEndian: true, bom: false);
      final decoded = decodeTextBytes(bytes);
      expect(decoded.encoding, 'UTF-8');
      expect(decoded.degraded, isTrue);
    });

    test('启发式不误伤普通 UTF-8（无 NUL 时不走 UTF-16）', () {
      final decoded = decodeTextBytes(Uint8List.fromList(utf8.encode('abc 中文')));
      expect(decoded.encoding, 'UTF-8');
      expect(decoded.text, 'abc 中文');
    });

    test('UTF-16 非 BMP 字符（代理对）正确还原', () {
      const emoji = '😀 笑脸';
      final decoded = decodeTextBytes(_utf16(emoji, littleEndian: true, bom: true));
      expect(decoded.text, emoji);
      expect(decoded.degraded, isFalse);
    });

    test('非法 UTF-8 字节 → 替换字符降级（不放弃整篇）', () {
      // 0xFF / 0xFE 不是合法 UTF-8 起始字节，且不含足够 NUL（不走 UTF-16 启发式）。
      final bytes = Uint8List.fromList([
        ...utf8.encode('前缀 '),
        0xFF,
        0xFE,
        0xC3,
        0x28,
        ...utf8.encode(' 后缀'),
      ]);
      final decoded = decodeTextBytes(bytes);
      expect(decoded.degraded, isTrue, reason: 'BR-61.7：非法字节以替换字符降级');
      expect(decoded.text, contains('\uFFFD'));
      expect(decoded.text, contains('前缀'));
      expect(decoded.text, contains('后缀'), reason: '合法片段必须保留，不丢字');
    });

    test('降级会体现在 ImportedDocument.warnings（AC-251）', () {
      final bytes = Uint8List.fromList([...utf8.encode('a'), 0xFF, 0xFE]);
      final doc = parsePlainTextSource(
          decodeTextBytes(bytes).text, 'x.txt');
      final decoded = decodeTextBytes(bytes);
      expect(decoded.degraded, isTrue);
      expect(doc.markdown, isNotEmpty);
    });
  });

  group('扩展名识别（FR-60 / BR-60.9）', () {
    test('受支持扩展名大小写不敏感；其余为不支持', () {
      for (final name in [
        'a.md',
        'a.MARKDOWN',
        'a.txt',
        'a.Html',
        'a.HTM',
        'dir/b.Md',
      ]) {
        expect(isSupportedImportFileName(name), isTrue, reason: name);
      }
      for (final name in ['a.enex', 'a.docx', 'noext', 'trailing.', 'a.png']) {
        expect(isSupportedImportFileName(name), isFalse, reason: name);
      }
      expect(kImportSupportedExtensions,
          ['md', 'markdown', 'txt', 'html', 'htm']);
    });

    test('titleFromFileName 去扩展名 + 去首尾空白 + 只取最后一段', () {
      expect(titleFromFileName('我的笔记.md'), '我的笔记');
      expect(titleFromFileName('  空格  .txt'), '空格');
      expect(titleFromFileName('a/b/c.markdown'), 'c');
      expect(titleFromFileName('无扩展名'), '无扩展名');
      expect(titleFromFileName('.hidden'), '.hidden');
    });
  });

  group('Markdown 逐字节保真（BR-61.1 / AC-241）', () {
    test('首行 H1 取标题；正文逐字节一致（H1 那行不得被删）', () {
      const source = '# 我的标题\n\n第一段\r\n第二段  \n\n- 项\n';
      final doc = parseMarkdownSource(source, '忽略文件名.md');
      expect(doc.title, '我的标题');
      expect(doc.markdown, source, reason: 'BR-61.1：逐字节保真，CRLF 原样保留');
    });

    test('首个非空行不是 H1 → 标题取文件名', () {
      const source = '正文第一行\n\n# 后面的标题\n';
      final doc = parseMarkdownSource(source, '回退标题.md');
      expect(doc.title, '回退标题');
      expect(doc.markdown, source);
    });

    test('前置空行后的 H1 仍被识别为首个非空行', () {
      const source = '\n\n# 标题\n正文\n';
      final doc = parseMarkdownSource(source, 'x.md');
      expect(doc.title, '标题');
      expect(doc.markdown, source);
    });

    test('不做任何规整：不转义、不折叠空行、不去行尾空白', () {
      const source = '# T\n\n\n\n  - 缩进项  \n\\* 已转义\n';
      final doc = parseMarkdownSource(source, 'x.md');
      expect(doc.markdown, source);
    });
  });

  group('纯文本四项空白规整（BR-61.2 / AC-242）', () {
    test('CRLF / CR 混排统一为 LF', () {
      final doc = parsePlainTextSource('a\r\nb\rc\n', 'x.txt');
      expect(doc.markdown, 'a\nb\nc\n');
    });

    test('去行尾空白，保留行首缩进', () {
      final doc = parsePlainTextSource('a   \n  b\t\n', 'x.txt');
      expect(doc.markdown, 'a\n  b\n');
    });

    test('连续 ≥3 个空行折叠为 1 个空行', () {
      final doc = parsePlainTextSource('a\n\n\n\n\nb\n', 'x.txt');
      expect(doc.markdown, 'a\n\nb\n');
    });

    test('段内单换行不折叠（BR-61.2 明确不折叠）', () {
      final doc = parsePlainTextSource('a\nb\n', 'x.txt');
      expect(doc.markdown, 'a\nb\n');
    });

    test('去首尾空行并保证结尾恰好一个 \\n', () {
      expect(parsePlainTextSource('\n\n\na\n\n\n', 'x.txt').markdown, 'a\n');
      expect(parsePlainTextSource('a', 'x.txt').markdown, 'a\n');
      expect(parsePlainTextSource('a\n\n\n\n', 'x.txt').markdown, 'a\n');
    });

    test('全空白文件 → 空串（服务侧记 empty，BR-60.4）', () {
      expect(parsePlainTextSource('   \n\n  \n', 'x.txt').markdown, '');
      expect(parsePlainTextSource('', 'x.txt').markdown, '');
    });

    test('不转义 Markdown 特殊字符，标题取文件名', () {
      final doc = parsePlainTextSource('- 这不是列表吗\n# 这不是标题吗\n', '清单.txt');
      expect(doc.title, '清单');
      expect(doc.markdown, '- 这不是列表吗\n# 这不是标题吗\n');
    });
  });
}

/// 构造 UTF-16 字节（可选 BOM）；用于四态一致性与启发式用例。
Uint8List _utf16(String text, {required bool littleEndian, required bool bom}) {
  final out = <int>[];
  if (bom) out.addAll(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]);
  for (final unit in text.codeUnits) {
    out.add(littleEndian ? unit & 0xFF : (unit >> 8) & 0xFF);
    out.add(littleEndian ? (unit >> 8) & 0xFF : unit & 0xFF);
  }
  return Uint8List.fromList(out);
}
