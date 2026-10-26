/// 补丁 `v0.16.3`（FR-91 / BR-91.4）：附件引用插入形态随类型。
///
/// 覆盖：`EditorFormat.insertAttachment` 的两种形态（图片 `![…]` / 其它 `[…](sui://…)`）、
/// **独占块**语义（前后各留空行、文末补换行）、光标落引用之后，以及产出的引用能被
/// `attachmentRefs` 以正确类型识别（保证格式 / 预览态走附件卡片而不是坏图占位）。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('AttachmentRefInsertion（FR-91 / BR-91.4）', () {
    const sha = 'a1b2c3d4e5f60718293a4b5c6d7e8f901234567890abcdef1234567890abcdef';

    test('图片形态与 insertImage 完全一致', () {
      final a = EditorFormat.insertAttachment(
        '正文',
        1,
        1,
        filename: '图.png',
        sha256: sha,
        isImage: true,
      );
      final b = EditorFormat.insertImage(
        '正文',
        1,
        1,
        filename: '图.png',
        sha256: sha,
      );
      expect(a.text, b.text);
      expect(a.selectionStart, b.selectionStart);
      expect(a.text, contains('![图.png](sui://$sha)'));
    });

    test('非图片产出附件链接（不是图片引用）且为独占块', () {
      final r = EditorFormat.insertAttachment(
        '甲\n乙',
        1,
        1,
        filename: '报告.pdf',
        sha256: sha,
        isImage: false,
      );
      expect(
        r.text,
        '甲\n\n[报告.pdf](sui://$sha)\n\n乙',
        reason: '左右各保证一个空行，正文其余字节逐字不动',
      );
      expect(r.text, isNot(contains('![')), reason: '非图片不得写成图片引用');

      // 光标落引用之后（即 trailing 之后、after 之前）。
      final token = '[报告.pdf](sui://$sha)';
      expect(r.selectionStart, '甲\n\n$token\n'.length);
      expect(r.selectionEnd, r.selectionStart, reason: '折叠光标');
    });

    test('文末插入：右侧补一个换行，光标可在引用下方落点', () {
      final r = EditorFormat.insertAttachment(
        '甲',
        1,
        1,
        filename: 'b.txt',
        sha256: sha,
        isImage: false,
      );
      expect(r.text, '甲\n\n[b.txt](sui://$sha)\n');
      expect(r.selectionStart, r.text.length, reason: '光标落在文末（引用之后的空行行首）');
    });

    test('空正文插入', () {
      final r = EditorFormat.insertAttachment(
        '',
        0,
        0,
        filename: 'c.zip',
        sha256: sha,
        isImage: false,
      );
      expect(r.text, '[c.zip](sui://$sha)\n');
    });

    test('产出可被 attachmentRefs 按类型识别', () {
      final img = EditorFormat.insertAttachment(
        '',
        0,
        0,
        filename: '图.png',
        sha256: sha,
        isImage: true,
      );
      final pdf = EditorFormat.insertAttachment(
        '',
        0,
        0,
        filename: '报告.pdf',
        sha256: sha,
        isImage: false,
      );

      final imgRefs = EditorFormat.attachmentRefs(img.text);
      expect(imgRefs, hasLength(1));
      expect(imgRefs.single.isImage, isTrue);
      expect(imgRefs.single.sha256, sha);
      expect(imgRefs.single.label, '图.png');

      final pdfRefs = EditorFormat.attachmentRefs(pdf.text);
      expect(pdfRefs, hasLength(1));
      expect(pdfRefs.single.isImage, isFalse, reason: 'PDF 必须走附件链接形态');
      expect(pdfRefs.single.corrupt, isFalse);
      expect(pdfRefs.single.label, '报告.pdf');
    });

    test('不改动选区之外的字节（含既有引用）', () {
      const src = '前文\n\n[旧.pdf](sui://$sha)\n\n后文';
      final at = src.indexOf('后文');
      final r = EditorFormat.insertAttachment(
        src,
        at,
        at,
        filename: '新.pdf',
        sha256: sha,
        isImage: false,
      );
      expect(r.text, contains('[旧.pdf](sui://$sha)'), reason: '既有引用逐字保留');
      expect(r.text, endsWith('后文'));
      expect(EditorFormat.attachmentRefs(r.text), hasLength(2));
    });
  });
}
