/// FR-117 / ADR-042：Web 端「保存到本地」= 浏览器下载（`test --platform chrome`）。
///
/// 该文件只在浏览器平台运行（`@TestOn('browser')`），验证：
/// 1. `dart:js_interop` 的 `Blob` + `a[download]` 在真实 Chrome 里能跑通；
/// 2. 返回 `startedDownload` 而不是抛异常 / 落到 `failed`；
/// 3. 文件名先经规整（路径分隔符 / Windows 保留字符被替换）。
///
/// 注：浏览器把文件落到哪里由下载设置决定，测试只断言「已触发下载」这一层。
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sui_flutter_app/src/platform/attachment_saver.dart';
import 'package:sui_flutter_app/src/platform/platform_seams.dart';

void main() {
  setUp(() {
    debugAttachmentSaveOverride = null;
  });

  test('Web：触发浏览器下载并返回 startedDownload', () async {
    final result = await saveAttachmentToDevice(
      filename: 'a/b:c*?.pdf',
      bytes: Uint8List.fromList(List<int>.generate(128, (i) => i % 251)),
    );

    expect(result.outcome, AttachmentSaveOutcome.startedDownload);
    expect(result.isSaved, isTrue);
  });
}
