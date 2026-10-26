/// 补丁 `v0.16.4`（FR-92 / AC-527\~AC-533）：受保护通道载荷的平台接缝门禁。
///
/// 三组：
/// 1. **线路一致**——生产用的 `sealChannelEnvelope`（大载荷走工作 isolate）与
///    `sealChannelEnvelopeInline`（参考实现）**逐字节相等**，且能解回原文；
///    Spike 向量（Go / Dart 双方验证过）同样由生产路径复现。
/// 2. **主线程停顿**——8 MiB 封装 / 解封期间 UI isolate 的最大停顿 < 400 ms
///    （旧实现约 0.9 s / 0.8 s，会明显卡顿）。
/// 3. **失败语义**——篡改 tag / 非法 base64 抛 `ChannelPayloadException` 且文案不变；
///    大载荷（isolate 路径）同样如此（异常不跨 isolate 丢类型）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

void main() {
  final key = List<int>.generate(32, (i) => i);
  final nonce = List<int>.generate(12, (i) => i + 1);
  final aad = Uint8List.fromList(utf8.encode('PUT\n/api/v1/blobs/x\nreq'));

  group('ChannelPayloadEquivalence（AC-527 / AC-528 / AC-533）', () {
    test('Spike 向量：生产路径封装的字节与既有向量一致', () async {
      final sealed = await sealChannelEnvelope(
        key: _hex('04da26d6647c364b952145871cc6cf3f547700e1096d0a209b75a71762767fde'),
        nonce: _hex('000000000000000000000001'),
        plaintext: Uint8List.fromList(utf8.encode('随手记 Sui spike-003')),
        aad: Uint8List.fromList(utf8.encode('nb-1|note-1|content')),
      );
      expect(
        utf8.decode(sealed),
        'AQEAAAAAAAAAAAAAAAE7RQzjmheTxZ9NtvnqTKlpBceBXBtXhN/nZ5Ryql5t/G2uutGpaSs=',
        reason: '工作 isolate 只是执行位置变化，线路字节必须与 v0.16.3 完全一致',
      );
    });

    // 64 KiB 是 isolate 阈值：边界两侧都要能正确往返（AC-533）。
    for (final size in <int>[
      1024,
      kChannelOffMainThreshold - 1,
      kChannelOffMainThreshold,
      kChannelOffMainThreshold + 1,
      8 * 1024 * 1024,
    ]) {
      test('$size 字节：与参考实现逐字节一致且可解回', () async {
        final plain = _payload(size);
        final viaSeam = await sealChannelEnvelope(
          key: key,
          nonce: nonce,
          // 接缝在 ≥ 阈值时会**转移**入参所有权，故传副本，保留 plain 做对照。
          plaintext: Uint8List.fromList(plain),
          aad: aad,
        );
        final reference = await sealChannelEnvelopeInline(
          key: key,
          nonce: nonce,
          plaintext: plain,
          aad: aad,
        );
        expect(viaSeam, orderedEquals(reference));

        final back = await openChannelEnvelope(
          key: key,
          envelope: viaSeam,
          aad: aad,
        );
        expect(back, orderedEquals(plain));

        final backInline = await openChannelEnvelopeInline(
          key: key,
          envelope: reference,
          aad: aad,
        );
        expect(backInline, orderedEquals(plain));
      });
    }
  });

  group('ChannelPayloadIsolation（AC-530 / AC-531）', () {
    test('8 MiB 封装：主 isolate 最大停顿 < 400 ms', () async {
      final plain = _payload(8 * 1024 * 1024);
      final lag = _LagMonitor()..start();
      final sealed = await sealChannelEnvelope(
        key: key,
        nonce: nonce,
        plaintext: plain,
        aad: aad,
      );
      // 关键：让阻塞期间过期的 timer 先落地，否则会把证据丢掉（原地实现会漏报）。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      lag.stop();
      expect(sealed, isNotEmpty);
      expect(
        lag.maxGapMs,
        lessThan(400),
        reason: '大载荷封装必须离开 UI isolate（原地实现约 900 ms）',
      );
    });

    test('8 MiB 解封：主 isolate 最大停顿 < 400 ms', () async {
      final plain = _payload(8 * 1024 * 1024);
      final sealed = await sealChannelEnvelopeInline(
        key: key,
        nonce: nonce,
        plaintext: plain,
        aad: aad,
      );
      final lag = _LagMonitor()..start();
      final back = await openChannelEnvelope(
        key: key,
        envelope: sealed,
        aad: aad,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      lag.stop();
      expect(back.length, plain.length);
      expect(
        lag.maxGapMs,
        lessThan(400),
        reason: '大载荷解封必须离开 UI isolate（原地实现约 800 ms）',
      );
    });
  });

  group('ChannelPayloadErrors（BR-92.3）', () {
    test('非法 base64（大载荷 isolate 路径）→ 文案不变', () async {
      // 0x21（'!'）不是 base64 字符，确保解码阶段就失败。
      final bogus = Uint8List.fromList(List<int>.filled(128 * 1024, 0x21));
      await expectLater(
        openChannelEnvelope(key: key, envelope: bogus, aad: aad),
        throwsA(isA<ChannelPayloadException>().having(
          (e) => e.message,
          'message',
          '响应不是合法 base64 封装',
        )),
      );
    });

    test('篡改 tag（大载荷 isolate 路径）→ 校验失败文案不变', () async {
      final plain = _payload(128 * 1024);
      final sealed = await sealChannelEnvelope(
        key: key,
        nonce: nonce,
        plaintext: plain,
        aad: aad,
      );
      final raw = base64.decode(utf8.decode(sealed));
      raw[raw.length - 1] ^= 0x01;
      final tampered = Uint8List.fromList(utf8.encode(base64.encode(raw)));
      await expectLater(
        openChannelEnvelope(key: key, envelope: tampered, aad: aad),
        throwsA(isA<ChannelPayloadException>().having(
          (e) => e.message,
          'message',
          '响应校验失败（密文被篡改或 AAD 不符）',
        )),
      );
    });

    test('封装过短（isolate 路径）→ 文案不变', () async {
      final tiny = Uint8List.fromList(utf8.encode('AAAA'));
      await expectLater(
        openChannelEnvelope(key: key, envelope: tiny, aad: aad),
        throwsA(isA<ChannelPayloadException>().having(
          (e) => e.message,
          'message',
          '响应封装过短',
        )),
      );
    });
  });
}

Uint8List _payload(int size) {
  final out = Uint8List(size);
  for (var i = 0; i < size; i += 4096) {
    out[i] = (i ~/ 4096) % 251;
  }
  return out;
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 主 isolate 停顿检测：`Timer.periodic(5ms)` + 每次 tick 记录与上次的间隔。
class _LagMonitor {
  Timer? _timer;
  final Stopwatch _since = Stopwatch();
  int maxGapMs = 0;

  void start() {
    _since
      ..reset()
      ..start();
    _timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final gap = _since.elapsedMilliseconds;
      if (gap > maxGapMs) maxGapMs = gap;
      _since
        ..reset()
        ..start();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
