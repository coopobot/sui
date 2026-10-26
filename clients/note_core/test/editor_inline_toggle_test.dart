/// M15 单测：格式指令的**记号集合语义**（FR-80 / BR-80.1~80.3）。
///
/// **红检**（回退源文件再跑本文件）：
/// - 逐字点斜体：第 2 步（`*甲*乙丙丁` 里选 `乙`）改动前会被误判为「取消」→ 得 `甲乙丙丁`，
///   本文件第一条用例失败；
/// - `*甲**乙**丙**丁*` 全选取消：改动前只删一对标记、内部残留合并成 3 个 `**` → 失败；
/// - `这是 *一* 段 和 *二* 的文字` 全选取消：改动前**又包一层** → 失败。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

FormatResult _italic(String text, int s, int e) =>
    EditorFormat.apply(FormatCommand.italic, text, s, e);

void main() {
  group('InlineToggleMarkerSet（FR-80 / BR-80.1~80.2）', () {
    test('逐字点斜体：4 次单字包裹**不得**互相吞并，全选再点才取消', () {
      // 用户真实路径：`甲乙丙丁` 里逐个选字点斜体（每次选区 `[i*3, i*3+1)`）。
      // 关键：第 2 步选区起点正好等于相邻对的 `close.end`（紧贴）——必须**不**被吸收，
      // 否则会误走「取消」分支、把「甲」的斜体吞掉（v0.15.0 主线复核实测缺陷）。
      var text = '甲乙丙丁';
      for (var i = 0; i < 4; i++) {
        final r = _italic(text, i * 3, i * 3 + 1);
        text = r.text;
        if (i == 0) expect(text, '*甲*乙丙丁');
        if (i == 1) expect(text, '*甲**乙*丙丁', reason: '不得吞掉「甲」的斜体');
        if (i == 2) expect(text, '*甲**乙**丙*丁');
      }
      expect(text, '*甲**乙**丙**丁*');

      final r = _italic(text, 0, text.length);
      expect(r.text, '甲乙丙丁', reason: 'BR-80.1：一次删净区间内全部同类记号');
      expect(r.text.contains('*'), isFalse);
      expect(r.selectionStart, 0);
      expect(r.selectionEnd, 4, reason: '新选区覆盖内容');
    });

    test('相邻多段斜体（旧逐字路径产物）：全选取消 → 记号全清、内容逐字保留', () {
      const src = '*甲**乙**丙**丁*';
      final r = _italic(src, 0, src.length);
      expect(r.text, '甲乙丙丁');
      expect(r.text.contains('*'), isFalse);
    });

    test('非相邻多段斜体：全选取消 → 不再多包一层', () {
      const src = '这是 *一* 段 和 *二* 的文字';
      final r = _italic(src, 0, src.length);
      expect(r.text, '这是 一 段 和 二 的文字');
    });

    test('单段往返幂等：abc → *abc* → 内容选区再点 → abc', () {
      final r1 = _italic('abc', 0, 3);
      expect(r1.text, '*abc*');
      expect(r1.selectionStart, 1);
      expect(r1.selectionEnd, 4);
      final r2 = _italic(r1.text, 1, 4);
      expect(r2.text, 'abc');
    });

    test('加粗不被斜体吞（BR-80.2 只删同类）：**bold** 内选 bold 加斜体', () {
      final r = _italic('**bold**', 2, 6);
      expect(r.text, '***bold***', reason: '应包裹为斜体，而非吞掉加粗星号');
    });

    test('混排：*甲* **乙** *丙* 全选取消斜体 → 加粗逐字不动', () {
      const src = '*甲* **乙** *丙*';
      final r = _italic(src, 0, src.length);
      expect(r.text, '甲 **乙** 丙');
    });

    test('相邻多段高亮同样一次性取消', () {
      const src = '==甲====乙==';
      final r = EditorFormat.apply(FormatCommand.highlight, src, 0, src.length);
      expect(r.text, '甲乙');
    });

    test('相邻多段删除线同样一次性取消', () {
      const src = '~~甲~~~~乙~~';
      final r = EditorFormat.apply(
          FormatCommand.strikethrough, src, 0, src.length);
      expect(r.text, '甲乙');
    });

    test('既有口径不回归：**x** 全选取消；选区只覆盖一侧标记也取消整对', () {
      final all = EditorFormat.apply(FormatCommand.bold, '**x**', 0, 5);
      expect(all.text, 'x');
      // 选区只覆盖一侧标记：对区间与选区相交 → 仍走取消（标记即格式）。
      final oneSide = _italic('*abc*', 0, 1);
      expect(oneSide.text, 'abc');
    });

    test('高亮与删除线互不混淆：~~a~~ 选 a 加高亮 → ~~==a==~~（既有口径）', () {
      final r = EditorFormat.apply(FormatCommand.highlight, '~~a~~', 2, 3);
      expect(r.text, '~~==a==~~', reason: '高亮不吞掉既有删除线标记');
    });
  });
}
