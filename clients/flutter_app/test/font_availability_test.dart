import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sui_flutter_app/src/ui/appearance/font_availability.dart';
import 'package:sui_flutter_app/src/ui/appearance/font_catalog.dart';

/// 假量测器：只有 `FakeFont` 与哨兵族名宽度不同（=「已安装」），其余落回哨兵度量。
FontAvailability _fakeAvailability() => FontAvailability(
      measurer: (family, sample) =>
          family == 'FakeFont' ? 90 : 50, // 哨兵与「未安装族名」同为 50
    );

void main() {
  group('FontAvailability（量宽判据，BR-65.3 / AC-289）', () {
    test('可解析族名（宽度不同于哨兵）→ 可用', () {
      expect(_fakeAvailability().isAvailable('FakeFont'), isTrue);
    });

    test('未安装族名（宽度同哨兵）→ 不可用', () {
      expect(_fakeAvailability().isAvailable('NoSuchFont'), isFalse);
      expect(FontAvailability.sentinelFamily, isNotEmpty);
    });

    test('available() 恒保留「跟随系统」，其余按探测过滤', () {
      final kept = _fakeAvailability()
          .available(const <FontOption>[
            kSystemFontOption,
            FontOption('假字体', 'FakeFont'),
            FontOption('不存在的字体', 'NoSuchFont'),
          ])
          .map((o) => o.family)
          .toList();
      expect(kept, <String?>[null, 'FakeFont']);
    });

    test('缓存：同一族名只量测一次（目标 + 哨兵各一次）', () {
      var calls = 0;
      final fonts = FontAvailability(measurer: (family, sample) {
        calls++;
        return family == FontAvailability.sentinelFamily ? 50 : 90;
      });
      expect(fonts.isAvailable('FakeFont'), isTrue);
      expect(fonts.isAvailable('FakeFont'), isTrue);
      expect(calls, 2, reason: '第二次命中缓存，不应再量测');
    });

    test('isOptionUsable：跟随系统（null / 空串）恒可用', () {
      final fonts = _fakeAvailability();
      expect(fonts.isOptionUsable(null), isTrue);
      expect(fonts.isOptionUsable(''), isTrue);
      expect(fonts.isOptionUsable('NoSuchFont'), isFalse);
    });
  });

  group('字体清单（分平台预置，BR-65.4）', () {
    test('界面字体含微软雅黑族，且**不含**等宽', () {
      final windows = uiFontOptions(TargetPlatform.windows);
      expect(windows.map((o) => o.family), contains('Microsoft YaHei'));
      expect(windows.map((o) => o.family), contains('SimSun'));
      expect(windows.any((o) => o.family == 'Consolas'), isFalse);
      expect(windows.first.family, isNull, reason: '首项应为「跟随系统」');
    });

    test('笔记正文字体在公共候选之外多一项「等宽」', () {
      final body = bodyFontOptions(TargetPlatform.windows);
      expect(body.any((o) => o.family == 'Consolas'), isTrue);
      expect(body.length, uiFontOptions(TargetPlatform.windows).length + 1);
    });

    test('macOS / Android / Linux 各自有对应候选', () {
      expect(uiFontOptions(TargetPlatform.macOS).map((o) => o.family),
          contains('PingFang SC'));
      expect(uiFontOptions(TargetPlatform.android).map((o) => o.family),
          contains('sans-serif'));
      expect(uiFontOptions(TargetPlatform.linux).map((o) => o.family),
          contains('Noto Sans CJK SC'));
    });

    test('偏好值 ↔ 族名互转（system ↔ null）', () {
      expect(fontValueOfFamily(null), 'system');
      expect(fontValueOfFamily(''), 'system');
      expect(fontValueOfFamily('SimSun'), 'SimSun');
      expect(fontFamilyOfValue('system'), isNull);
      expect(fontFamilyOfValue(null), isNull);
      expect(fontFamilyOfValue('SimSun'), 'SimSun');
    });

    test('fontOptionLabel：未知族名回退为族名本身（供「不可用（已回退）」呈现）', () {
      expect(fontOptionLabel(null, uiFontOptions(TargetPlatform.windows)),
          contains('跟随系统'));
      expect(fontOptionLabel('SimSun', uiFontOptions(TargetPlatform.windows)),
          contains('宋体'));
      expect(fontOptionLabel('GhostFont', uiFontOptions(TargetPlatform.windows)),
          'GhostFont');
    });
  });

  test('默认量测器（TextPainter）对中英混排返回正宽度', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(measureTextWidth(null, FontAvailability.sampleText), greaterThan(0));
    expect(
      measureTextWidth(FontAvailability.sentinelFamily, FontAvailability.sampleText),
      greaterThan(0),
    );
  });
}
