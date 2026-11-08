/// FR-110 / ADR-040：**Android 用系统默认应用打开附件**的平台层测试。
///
/// 覆盖四件事（对应 AC-643 与 AC-641 / AC-642 的可断言部分）：
/// 1. **平台分派**：桌面三平台仍产出原来的壳层命令（`cmd /c start` / `open` /
///    `xdg-open`）——Android 不回归桌面；Android / iOS 没有壳层命令（ADR-040 背景 ④）。
/// 2. **Android 走原生通道**：MIME 由文件名推断（`application/pdf`）、临时文件落在
///    授权范围内的同名文件、结果为「已打开」且**不启动回写监视**（只读授权）。
/// 3. **失败分流**：原生返回 `nohandler` / `error` / 缺省 分别映射到
///    「无可用应用」/「出错」/「平台不支持」三套文案（AC-637 / AC-642）。
/// 4. **清理**：失败与不支持时临时目录被删掉，不留垃圾（BR-110.4）。
///
/// 纪律：本组是纯 `test`（无 widget、无假时钟），因为要真实读写临时文件
/// （`testWidgets` 的假时钟不推进真实 IO，Agents.md §5.18 第 4 条）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sui_flutter_app/src/platform/attachment_open_result.dart';
import 'package:sui_flutter_app/src/platform/attachment_opener_io.dart';
import 'package:sui_flutter_app/src/platform/platform_seams.dart';

/// 一次「Android 打开」的记录：原生侧收到的三个参数。
class _OpenCall {
  _OpenCall(this.path, this.filename, this.mime);
  final String path;
  final String filename;
  final String mime;
}

void main() {
  late Directory base;
  late List<_OpenCall> calls;

  /// 装好「模拟 Android」的接缝：临时目录落在真实 `base` 下，通道用记录桩。
  void installAndroidSeam({required String? code}) {
    debugOpenTargetOsOverride = 'android';
    debugOpenTempBasePathOverride = base.path;
    debugAndroidOpenFileOverride =
        ({required String path, required String filename, required String mime}) async {
      calls.add(_OpenCall(path, filename, mime));
      return code;
    };
  }

  setUp(() async {
    base = await Directory.systemTemp.createTemp('sui_att_test_');
    calls = <_OpenCall>[];
    debugOpenTargetOsOverride = null;
    debugOpenTempBasePathOverride = null;
    debugAndroidOpenFileOverride = null;
  });

  tearDown(() async {
    debugOpenTargetOsOverride = null;
    debugOpenTempBasePathOverride = null;
    debugAndroidOpenFileOverride = null;
    try {
      if (await base.exists()) await base.delete(recursive: true);
    } catch (_) {}
  });

  Uint8List pdf() => Uint8List.fromList('%PDF-1.4\nsui\n'.codeUnits);

  group('平台分派（shellOpenCommand）', () {
    test('桌面三平台命令保持原样（不回归）', () {
      expect(
        shellOpenCommand('windows', r'C:\tmp\a.pdf'),
        ['cmd', '/c', 'start', '', r'C:\tmp\a.pdf'],
      );
      expect(shellOpenCommand('macos', '/tmp/a.pdf'), ['open', '/tmp/a.pdf']);
      expect(shellOpenCommand('linux', '/tmp/a.pdf'), ['xdg-open', '/tmp/a.pdf']);
    });

    test('Android / iOS 没有系统壳层', () {
      expect(shellOpenCommand('android', '/data/a.pdf'), isNull);
      expect(shellOpenCommand('ios', '/data/a.pdf'), isNull);
    });
  });

  group('原生返回码 → 四态（outcomeForAndroidCode）', () {
    test('ok / nohandler / error / 缺省', () {
      expect(outcomeForAndroidCode('ok'), ExternalOpenOutcome.opened);
      expect(outcomeForAndroidCode('nohandler'), ExternalOpenOutcome.noHandler);
      expect(outcomeForAndroidCode('error'), ExternalOpenOutcome.failed);
      expect(outcomeForAndroidCode(null), ExternalOpenOutcome.unsupported);
      expect(outcomeForAndroidCode('unknown'), ExternalOpenOutcome.unsupported);
    });
  });

  group('Android 打开（AC-635 / AC-638 / AC-643）', () {
    test('已交给系统：MIME 正确、临时文件同名、不监视回写', () async {
      installAndroidSeam(code: 'ok');

      final result = await openExternally(
        filename: '方案.pdf',
        bytes: pdf(),
      );

      expect(result.outcome, ExternalOpenOutcome.opened);
      expect(result.isOpened, isTrue);
      expect(calls, hasLength(1));
      // MIME 由文件名推断，而不是把大类 `pdf` / `image` 当 MIME 传下去。
      expect(calls.single.mime, 'application/pdf');
      expect(calls.single.filename, '方案.pdf');
      expect(calls.single.path, endsWith('方案.pdf'));
      // 必须落在**固定**授权根 `sui_att/<唯一子目录>/` 下：FileProvider 的
      // `<cache-path path="sui_att">` 是精确匹配，路径形状一变 URI 就生成失败。
      expect(
        calls.single.path,
        contains('${Platform.pathSeparator}sui_att${Platform.pathSeparator}'),
      );
      // 只读授权 → 不回写、不空转监视（BR-110.6）。
      expect(result.watchForEdits, isFalse);
      // 文件真的落盘了（原生侧据此取 content URI）。
      expect(File(result.path!).existsSync(), isTrue);
      expect(File(result.path!).readAsBytesSync(), pdf());

      await cleanupExternalFile(result.path!);
    });

    test('未知扩展名退化为 */*（仍让用户挑应用）', () async {
      installAndroidSeam(code: 'ok');

      final result = await openExternally(
        filename: 'mystery.blob',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      expect(result.outcome, ExternalOpenOutcome.opened);
      expect(calls.single.mime, '*/*');
      await cleanupExternalFile(result.path!);
    });

    test('无可用应用 → noHandler，且清理临时目录', () async {
      installAndroidSeam(code: 'nohandler');

      final result = await openExternally(filename: 'a.pdf', bytes: pdf());

      expect(result.outcome, ExternalOpenOutcome.noHandler);
      expect(result.path, isNull);
      expect(base.listSync(), isEmpty, reason: '失败路径必须不留临时文件');
    });

    test('原生报错 → failed', () async {
      installAndroidSeam(code: 'error');

      final result = await openExternally(filename: 'a.pdf', bytes: pdf());

      expect(result.outcome, ExternalOpenOutcome.failed);
      expect(base.listSync(), isEmpty);
    });

    test('通道未实现（旧原生 / iOS）→ unsupported', () async {
      installAndroidSeam(code: null);

      final result = await openExternally(filename: 'a.pdf', bytes: pdf());

      expect(result.outcome, ExternalOpenOutcome.unsupported);
      expect(base.listSync(), isEmpty);
    });
  });

  group('Android 授权根与清单一致（ADR-040 实测回填）', () {
    test('FileProvider 的 cache-path 与 Dart 侧临时目录常量逐字一致', () {
      // flutter test 的工作目录是包根（clients/flutter_app）。
      final xml = File(
        'android/app/src/main/res/xml/sui_file_paths.xml',
      ).readAsStringSync();
      expect(xml, contains('path="$kAndroidAttachmentScopeDir"'));
      // 反向：不允许再出现「带下划线尾巴」的旧值（那正是踩过的坑）。
      expect(xml, isNot(contains('path="${kAndroidAttachmentScopeDir}_"')));
    });
  });

  group('iOS / Web 口径不回归（AC-642）', () {
    test('iOS 无壳层 → 平台不支持，不留临时文件', () async {
      debugOpenTargetOsOverride = 'ios';
      debugOpenTempBasePathOverride = base.path;

      final result = await openExternally(filename: 'a.pdf', bytes: pdf());

      expect(result.outcome, ExternalOpenOutcome.unsupported);
      expect(result.path, isNull);
      expect(base.listSync(), isEmpty);
    });
  });
}
