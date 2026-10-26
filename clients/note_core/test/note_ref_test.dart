/// M15 单测：关联笔记引用（FR-75 / BR-75.1~75.2）。
///
/// 口径：正本恒为 `[标题](sui://note/<笔记ID>)`；裸 `sui://<uuid>` **禁止**（会被附件正则
/// 误判并截断，BR-75.1）。`links()` 必须保留笔记引用（是标准 Markdown 链接），
/// `attachmentRefs()` 对其**零命中**。
///
/// **红检**（回退源文件再跑本文件）：`kNoteRefPrefix` / `noteRefUrl` / `noteRefId` /
/// `noteRefAt` 尚不存在 → 编译失败；且 `links()` 会**丢弃**笔记引用 → 保留类用例失败。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('NoteRefUrl（FR-75）', () {
    test('scheme 常量与生成', () {
      expect(EditorFormat.kNoteRefPrefix, 'sui://note/');
      expect(EditorFormat.noteRefUrl('nb-1'), 'sui://note/nb-1');
      expect(
        EditorFormat.noteRefUrl('550e8400-e29b-41d4-a716-446655440000'),
        'sui://note/550e8400-e29b-41d4-a716-446655440000',
      );
    });

    test('解析：合法 ID / 大小写 / 两端空白', () {
      expect(EditorFormat.noteRefId('sui://note/nb-1'), 'nb-1');
      expect(EditorFormat.noteRefId('sui://note/AbC'), 'AbC',
          reason: 'ID 大小写原样返回');
      expect(EditorFormat.noteRefId(' sui://note/abc '), 'abc');
    });

    test('解析：空 ID / 多余路径段 / 大小写 / 空串一律 null', () {
      expect(EditorFormat.noteRefId('sui://note/'), isNull);
      expect(EditorFormat.noteRefId('sui://note/a/b'), isNull);
      expect(EditorFormat.noteRefId('sui://note'), isNull);
      expect(EditorFormat.noteRefId('SUI://NOTE/abc'), isNull,
          reason: '前缀大小写敏感（正本由 noteRefUrl 生成，恒为小写）');
      expect(EditorFormat.noteRefId(''), isNull);
      expect(EditorFormat.noteRefId('https://example.com'), isNull);
      expect(EditorFormat.noteRefId('sui://deadbeef'), isNull,
          reason: '裸 sui://<sha> 是附件引用，不是笔记引用');
    });
  });

  group('LinksKeepNoteRef（FR-75 / BR-75.1~75.2）', () {
    test('笔记引用保留为链接、普通链接保留、裸 sui:// 丢弃', () {
      const src = '[标题](sui://note/nb-1) 与 [站点](https://a.com) 与 [附件](sui://deadbeef)';
      final ls = EditorFormat.links(src);
      expect(ls.map((l) => l.url).toList(),
          ['sui://note/nb-1', 'https://a.com']);
      expect(ls.first.label, '标题');
    });

    test('链接区间落在正本上（`[` 到 `)` 之后）', () {
      const src = '[标题](sui://note/nb-1)';
      final l = EditorFormat.links(src).single;
      expect(l.start, 0);
      expect(l.end, src.length);
      expect(src.substring(l.start, l.end), src);
    });

    test('CRLF 正本下链接仍成立且偏移正确（FR-77）', () {
      const src = '[标题](sui://note/nb-1)\r\n[站点](https://a.com)';
      final ls = EditorFormat.links(src);
      expect(ls.map((l) => l.url).toList(),
          ['sui://note/nb-1', 'https://a.com']);
      expect(src.substring(ls.first.start, ls.first.end), '[标题](sui://note/nb-1)');
    });

    test('noteRefAt：命中笔记引用；普通链接与正文返回 null', () {
      const src = '[标题](sui://note/nb-1) [站点](https://a.com)';
      final at = EditorFormat.noteRefAt(src, 3);
      expect(at, isNotNull);
      expect(at!.url, 'sui://note/nb-1');
      expect(EditorFormat.noteRefAt(src, 30), isNull,
          reason: '普通链接不是笔记引用');
      expect(EditorFormat.noteRefAt(src, 100), isNull);
    });
  });

  group('AttachmentRefsUnaffected（现状锁定）', () {
    test('笔记引用对 attachmentRefs() 零命中', () {
      expect(EditorFormat.attachmentRefs('[标题](sui://note/nb-1)'), isEmpty);
      expect(EditorFormat.attachmentRefs('[笔记](sui://note/deadbeef)'), isEmpty);
      expect(
        EditorFormat.attachmentRefs(
            '[a](sui://note/550e8400-e29b-41d4-a716-446655440000)'),
        isEmpty,
      );
    });

    test('裸 sui://<sha256> 仍是附件引用（链接与图片两种形态）', () {
      expect(
        EditorFormat.attachmentRefs('[附件](sui://deadbeef)'),
        hasLength(1),
      );
      expect(
        EditorFormat.attachmentRefs('![图](sui://deadbeef)'),
        hasLength(1),
      );
      expect(
        EditorFormat.attachmentRefs('![图](sui://deadbeef)').single.sha256,
        'deadbeef',
      );
    });

    test('裸 sui://<uuid>（带横线）仍命中但被截断——BR-75.1 禁止它的原因', () {
      // 现状锁定：`_attachmentRefPattern` 的 `[0-9a-fA-F]+` 只吃到第一个 `-` 之前
      // （即 `550e8400`），故裸 `sui://<uuid>` 会被误判为附件并**截断**。
      // 笔记引用因此**必须**写作标准链接 `[标题](sui://note/<id>)`（BR-75.1）。
      final refs = EditorFormat.attachmentRefs(
          '[附件](sui://550e8400-e29b-41d4-a716-446655440000)');
      expect(refs, hasLength(1));
      expect(refs.single.sha256, '550e8400');
    });

    test('图片引用不算链接、笔记引用算链接（同一文档共存）', () {
      const src = '![图](sui://deadbeef) [标题](sui://note/nb-1)';
      final ls = EditorFormat.links(src);
      expect(ls, hasLength(1));
      expect(ls.single.url, 'sui://note/nb-1');
      expect(EditorFormat.attachmentRefs(src), hasLength(1));
    });
  });
}
