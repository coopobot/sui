/// FR-110 / ADR-040：`mimeTypeFor` —— 由文件名推断交给系统的**真实 MIME**。
///
/// 与 `mimeKindFor`（UI 选图标用的大类）严格区分：把 `image` / `pdf` 这类**大类**
/// 当 MIME 传给 Android `ACTION_VIEW`，一个应用都匹配不上，表现为「点开没反应」。
library;

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  group('常见类型', () {
    test('图片 / PDF / 文本 / 音视频 / 压缩包', () {
      expect(mimeTypeFor('a.png'), 'image/png');
      expect(mimeTypeFor('a.JPG'), 'image/jpeg');
      expect(mimeTypeFor('方案.pdf'), 'application/pdf');
      expect(mimeTypeFor('notes.md'), 'text/markdown');
      expect(mimeTypeFor('data.csv'), 'text/csv');
      expect(mimeTypeFor('log.txt'), 'text/plain');
      expect(mimeTypeFor('clip.html'), 'text/html');
      expect(mimeTypeFor('v.mp4'), 'video/mp4');
      expect(mimeTypeFor('a.mp3'), 'audio/mpeg');
      expect(mimeTypeFor('a.zip'), 'application/zip');
      expect(mimeTypeFor('r.docx'), contains('wordprocessingml'));
    });
  });

  group('推断不出来 → */*', () {
    test('无扩展名 / 未知扩展名 / 末尾是点', () {
      expect(mimeTypeFor('README'), '*/*');
      expect(mimeTypeFor('mystery.blob'), '*/*');
      expect(mimeTypeFor('weird.'), '*/*');
      expect(mimeTypeFor(''), '*/*');
    });
  });

  test('与 mimeKindFor 分属两套口径（大类不能当 MIME 用）', () {
    expect(mimeKindFor('a.pdf'), 'pdf');
    expect(mimeTypeFor('a.pdf'), 'application/pdf');
    expect(mimeTypeFor('a.pdf'), isNot(mimeKindFor('a.pdf')));
  });
}
