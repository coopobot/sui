/// M16（v0.16.0）编辑器契约单测（FR-88 / FR-89 / FR-83 的 note_core 部分）。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

String _sha([String ch = 'a']) => ch * 64;

void main() {
  group('BlockCommandCaret（块级指令：折叠光标 + 末行行尾 / FR-89）', () {
    test('无序列表：光标在 `- a` 行尾，不再整行选中', () {
      final r = EditorFormat.apply(FormatCommand.bulletList, 'a', 0, 0);
      expect(r.text, '- a');
      expect(r.selectionStart, 3);
      expect(r.selectionEnd, 3, reason: '必须是折叠光标');
    });

    test('有序列表：光标在 `1. a` 行尾', () {
      final r = EditorFormat.apply(FormatCommand.orderedList, 'a', 0, 0);
      expect(r.text, '1. a');
      expect(r.selectionStart, 4);
      expect(r.selectionEnd, 4);
    });

    test('勾选框空行：`- [ ] ` 行尾（偏移 6），可继续键入', () {
      final r = EditorFormat.apply(FormatCommand.taskList, '', 0, 0);
      expect(r.text, '- [ ] ');
      expect(r.selectionStart, 6);
      expect(r.selectionEnd, 6);
    });

    test('勾选框已有文字：`- [ ] a` 行尾', () {
      final r = EditorFormat.apply(FormatCommand.taskList, 'a', 0, 1);
      expect(r.text, '- [ ] a');
      expect(r.selectionStart, 7);
      expect(r.selectionEnd, 7);
    });

    test('缩进 / 反缩进：光标落行尾', () {
      final i = EditorFormat.apply(FormatCommand.indent, 'a', 0, 0);
      expect(i.text, '  a');
      expect(i.selectionStart, 3);
      expect(i.selectionEnd, 3);

      final o = EditorFormat.apply(FormatCommand.outdent, '  a', 2, 2);
      expect(o.text, 'a');
      expect(o.selectionStart, 1);
      expect(o.selectionEnd, 1);
    });

    test('标题 / 引用：光标落行尾', () {
      final h = EditorFormat.apply(FormatCommand.heading1, 'a', 0, 0);
      expect(h.text, '# a');
      expect(h.selectionStart, 3);
      final q = EditorFormat.apply(FormatCommand.blockquote, 'a', 0, 0);
      expect(q.text, '> a');
      expect(q.selectionStart, 3);
    });

    test('简化格式：光标落清理后文本末尾', () {
      final r = EditorFormat.apply(FormatCommand.clearFormat, '**a**', 0, 5);
      expect(r.text, 'a');
      expect(r.selectionStart, 1);
      expect(r.selectionEnd, 1);
    });

    test('多行选区：光标落最后一行行尾', () {
      final r = EditorFormat.apply(FormatCommand.bulletList, 'a\nb', 0, 3);
      expect(r.text, '- a\n- b');
      expect(r.selectionStart, 7);
      expect(r.selectionEnd, 7);
    });
  });

  group('WebClipRefs（网页原件引用 / FR-83）', () {
    final sha = _sha();
    final text = '前\n\n[网页原件](sui://webclip/$sha)\n\n后';

    test('解析出 start / end / label / sha256', () {
      final refs = EditorFormat.webClipRefs(text);
      expect(refs, hasLength(1));
      final ref = refs.single;
      expect(ref.label, '网页原件');
      expect(ref.sha256, sha);
      expect(text.substring(ref.start, ref.end),
          '[网页原件](sui://webclip/$sha)');
    });

    test('webClipRefAt 命中区间内外', () {
      final ref = EditorFormat.webClipRefs(text).single;
      expect(EditorFormat.webClipRefAt(text, ref.start), isNotNull);
      expect(EditorFormat.webClipRefAt(text, ref.end), isNotNull);
      expect(EditorFormat.webClipRefAt(text, 0), isNull);
    });

    test('links() 不把网页原件当普通链接', () {
      expect(EditorFormat.links(text), isEmpty);
      expect(EditorFormat.linkAt(text, 3), isNull);
    });

    test('笔记引用仍是链接', () {
      const t = '[目标](sui://note/n-1)';
      expect(EditorFormat.links(t), hasLength(1));
      expect(EditorFormat.noteRefId(EditorFormat.links(t).single.url), 'n-1');
    });

    test('整块删除：删除整行并只留一个空行，光标落删除点', () {
      final ref = EditorFormat.webClipRefs(text).single;
      final r = EditorFormat.deleteWebClip(text, ref);
      expect(r.text, '前\n\n后');
      expect(r.selectionStart, r.selectionEnd);
      expect(r.selectionStart, 3);
    });

    test('残缺引用不建原子块', () {
      final t = '[网页原件](sui://webclip/$sha';
      expect(EditorFormat.webClipRefs(t), isEmpty);
    });

    test('结构删除命中网页原件：整行删除、不逐字符咬坏', () {
      final ref = EditorFormat.webClipRefs(text).single;
      final r = EditorFormat.structuralDelete(
        text,
        ref.end,
        ref.end,
        backspace: true,
      );
      expect(r, isNotNull);
      expect(r!.text, '前\n\n后');
      expect(r.selectionStart, r.selectionEnd);
    });
  });
}
