/// FR-117 / ADR-042：附件「保存到本地 / 本机」的平台层单测。
///
/// 覆盖三件事：
/// 1. **文件名规整**（纯函数）：路径成分 / Windows 保留字符 / 首尾空白 / 空名回退 /
///    超长截断保留扩展名（BR-117.5 / AC-675）；
/// 2. **桌面写盘责任**：`file_picker` 在桌面只返回路径，应用必须自己写（ADR-042 决策 1）；
/// 3. **结果分流**：成功带完整路径、取消不写文件、写盘失败归 `failed`，均不抛出。
///
/// 纪律：本组是纯 `test`（无 widget、无假时钟），因为要真实读写临时文件
/// （Agents.md §5.18 第 4 条）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sui_flutter_app/src/platform/attachment_saver.dart';
import 'package:sui_flutter_app/src/platform/platform_seams.dart';

Uint8List _bytes([int n = 64]) =>
    Uint8List.fromList(List<int>.generate(n, (i) => i % 251));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sui-save-test-');
    debugAttachmentSaveOverride = null;
    debugSavePathOverride = null;
  });

  tearDown(() async {
    debugAttachmentSaveOverride = null;
    debugSavePathOverride = null;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });

  group('文件名规整（BR-117.5 / AC-675）', () {
    test('去路径成分与 Windows 保留字符', () {
      final name = sanitizeAttachmentFilename('a/b:c*?"<>|.pdf');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(r'\')));
      expect(name, isNot(contains(RegExp(r'[<>:"|?*]'))));
      expect(name, endsWith('.pdf'));
    });

    test('去首尾空白与结尾点号', () {
      expect(sanitizeAttachmentFilename(' 报告 .pdf '), '报告 .pdf');
      expect(sanitizeAttachmentFilename('a. '), 'a');
      expect(sanitizeAttachmentFilename('a...'), 'a');
    });

    test('空名 / 点号回退 attachment', () {
      expect(sanitizeAttachmentFilename(''), 'attachment');
      expect(sanitizeAttachmentFilename('   '), 'attachment');
      expect(sanitizeAttachmentFilename('..'), 'attachment');
      expect(sanitizeAttachmentFilename('a/'), 'a');
    });

    test('超长截断保留扩展名', () {
      final long = '${'长' * 200}.pdf';
      final name = sanitizeAttachmentFilename(long);
      expect(name.length, lessThanOrEqualTo(120));
      expect(name, endsWith('.pdf'));
    });
  });

  group('桌面分支：应用负责写盘（ADR-042 决策 1）', () {
    test('成功：返回完整路径，文件字节与附件一致', () async {
      final target = '${dir.path}${Platform.pathSeparator}报告.pdf';
      String? seenName;
      debugSavePathOverride = ({required String filename}) async {
        seenName = filename;
        return target;
      };

      final data = _bytes();
      final result = await saveAttachmentToDevice(
        filename: 'a/b:c*?.pdf',
        bytes: data,
      );

      expect(result.outcome, AttachmentSaveOutcome.saved);
      expect(result.isSaved, isTrue);
      expect(result.location, target);
      expect(seenName, isNotNull);
      expect(seenName, isNot(contains('/')));
      expect(seenName, isNot(contains(':')));
      expect(File(target).existsSync(), isTrue);
      expect(File(target).readAsBytesSync(), data);
    });

    test('取消：不落文件、结果为 cancelled', () async {
      debugSavePathOverride = ({required String filename}) async => null;

      final result = await saveAttachmentToDevice(
        filename: '报告.pdf',
        bytes: _bytes(),
      );

      expect(result.outcome, AttachmentSaveOutcome.cancelled);
      expect(result.isSaved, isFalse);
      expect(dir.listSync(), isEmpty);
    });

    test('写盘失败：目录不可写 / 不存在 → failed，不抛出', () async {
      final target =
          '${dir.path}${Platform.pathSeparator}missing${Platform.pathSeparator}x.pdf';
      debugSavePathOverride = ({required String filename}) async => target;

      final result = await saveAttachmentToDevice(
        filename: 'x.pdf',
        bytes: _bytes(),
      );

      expect(result.outcome, AttachmentSaveOutcome.failed);
    });
  });

  test('整平台接缝：debugAttachmentSaveOverride 优先于真实分派', () async {
    debugAttachmentSaveOverride =
        ({required String filename, required Uint8List bytes}) async =>
            const AttachmentSaveResult(AttachmentSaveOutcome.startedDownload);

    final result = await saveAttachmentToDevice(
      filename: 'a.pdf',
      bytes: _bytes(),
    );

    expect(result.outcome, AttachmentSaveOutcome.startedDownload);
    expect(debugSavePathOverride, isNull);
  });
}
