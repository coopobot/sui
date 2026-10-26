/// M15 单测：CRLF 容错（FR-77 / BR-77.2）。
///
/// 口径：行尾 `\r` 只在**扫描视图**内被剥除——正本字节一字不改，所有记号区间仍落在真实
/// 字符上、**不含 `\r`**（偏移契约 BR-27.1，spans 与正本逐码元等长）。
///
/// **红检**（把 `lib/src/format/editor_format.dart` 回退到改动前再跑本文件）：
/// - CRLF 下 `- [ ] 甲\r\n- [x] 乙` 只产出 `[bullet, task]`（勾选框 2 → 1）→ 首条用例失败；
/// - CRLF 下 `---\r` / `---` 下划线不成记号 → 分割线与 setext 两条用例失败；
/// - `orderedListNumbers('1. 甲\r\n1. 乙')` 得 `[null, 1]` → 纯读用例失败。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('EditorCrlfTolerance（FR-77 / BR-77.2）', () {
    test('任务项：LF / CRLF / 行尾单独 CR 三种正本都产出 task 记号', () {
      const lf = '- [ ] 甲\n- [x] 乙';
      const crlf = '- [ ] 甲\r\n- [x] 乙';
      const cr = '- [ ] 甲\r';

      for (final src in [lf, crlf, cr]) {
        expect(
          EditorFormat.syntaxMarkers(src)
              .any((m) => m.kind == SyntaxMarkerKind.task),
          isTrue,
          reason: '正本码元=${src.codeUnits}',
        );
      }

      // CRLF：**两行**都要成勾选框（改动前只认出第二行）。
      expect(
        EditorFormat.syntaxMarkers(crlf)
            .where((m) => m.kind == SyntaxMarkerKind.task)
            .length,
        2,
      );
    });

    test('分割线：CRLF 下 --- 产出 rule', () {
      const src = '甲\r\n\r\n---\r\n\r\n乙';
      final rules = EditorFormat.syntaxMarkers(src)
          .where((m) => m.kind == SyntaxMarkerKind.rule)
          .toList();
      expect(rules, hasLength(1));
      expect(rules.single.lineStart, 5);
    });

    test('setext 下划线：CRLF 下 标题 + --- 产出 setext', () {
      const src = '标题\r\n---\r\n丙';
      expect(
        EditorFormat.syntaxMarkers(src)
            .any((m) => m.kind == SyntaxMarkerKind.setext),
        isTrue,
      );
    });

    test('偏移契约：记号都在正本内、不以 \\r 起记号；记号序列与 LF 归一后一致', () {
      const src = '- [ ] 甲\r\n- [x] 乙\r\n\r\n---\r\n\r\n标题\r\n===\r\n';
      final markers = EditorFormat.syntaxMarkers(src);
      expect(markers, isNotEmpty);
      for (final m in markers) {
        expect(m.start, greaterThanOrEqualTo(0));
        expect(m.end, lessThanOrEqualTo(src.length));
        expect(m.end, greaterThan(m.start));
        // `\r` 从不被**单独**判为记号：区间首码元必是真实语法字符。
        expect(src[m.start], isNot('\r'), reason: '$m 不得以行尾 \\r 起记号');
      }
      // 容错只在**扫描视图**内：记号**类型序列**与 LF 归一后的正本完全一致
      // （BR-77.2 / BR-77.4）。注：`rule` / `setext` / `fence` 三类记号按 BR-72.2
      // 吸收整段行终止符，故 CRLF 下其区间**必然**包裹 `\r\n`——「区间不含 `\r`」
      // 对它们不成立，真正的不变量是「`\r` 不参与语法判定」。
      final lf = src.replaceAll('\r\n', '\n');
      expect(
        markers.map((m) => m.kind).toList(),
        EditorFormat.syntaxMarkers(lf).map((m) => m.kind).toList(),
      );
      // 正本本身逐码元不变（容错只发生在扫描视图内）。
      expect(src.length, 36);
    });

    test('容错不改正本：扫描与编号都是纯读函数', () {
      const src = '- [ ] 甲\r\n- [x] 乙';
      EditorFormat.syntaxMarkers(src);
      expect(src, '- [ ] 甲\r\n- [x] 乙');
      expect(EditorFormat.orderedListNumbers('1. 甲\r\n1. 乙'), [1, 2]);
    });

    test('边界：\\r 作**行内**分隔（真·lone-CR 行分隔）不由扫描器断行', () {
      // BR-77.3：真·lone-CR 正本由「输入归一」（粘贴时 `\r\n` / `\r` → `\n`）消除；
      // 扫描器只按 `\n` 断行、只剥**行尾** `\r`，故此处首项退化为 bullet 而非 task。
      // 本用例**如实锁定这一未覆盖面**（不宣称「所有空白偏差都已解决」，见 FR-77 末段）。
      const src = '- [ ] 甲\r- [x] 乙\r';
      final markers = EditorFormat.syntaxMarkers(src);
      expect(markers, hasLength(1));
      expect(markers.first.kind, SyntaxMarkerKind.bullet);
    });
  });

  group('PasteLineEndingNormalization（FR-77 / BR-77.3）', () {
    test('normalizeLineEndings 只归换行：不改空白、不补结尾换行', () {
      // 粘贴路径必须只做换行归一——若用**导入口径**的 `normalizePlainText`，
      // 「行内粘贴一个词」会被凭空补一个 `\n`（可见缺陷），故两者必须是**两个函数**。
      expect(normalizeLineEndings('前\r\n后'), '前\n后');
      expect(normalizeLineEndings('前\r后'), '前\n后');
      expect(normalizeLineEndings('一个词'), '一个词');
      expect(normalizeLineEndings(' 行尾  '), ' 行尾  ');
      expect(normalizeLineEndings('a\n\n\nb'), 'a\n\n\nb');
      expect(normalizeLineEndings(''), '');
    });

    test('normalizePlainText（导入口径）仍做四项规整，且与粘贴口径不同', () {
      expect(normalizePlainText('一个词'), '一个词\n');
      expect(normalizePlainText('a  \r\n\r\n\r\nb'), 'a\n\nb\n');
      expect(normalizeLineEndings('一个词') == normalizePlainText('一个词'), isFalse,
          reason: '两者必须是不同口径：粘贴不得补结尾换行');
    });
  });
}
