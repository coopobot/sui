import 'package:flutter/foundation.dart';

/// 「跟随系统」在偏好里的保留值（键值表存字符串）。
///
/// 用**哨兵串**而非空串：`DropdownButtonFormField` 的 `value == null` 表示「未选择」，
/// 会把「跟随系统」呈现成 hint 而不是选中项（§24.3 的默认项必须可见）。
const String kSystemFontValue = 'system';

/// 偏好值 → 字体族名（`system` → `null`）。
String? fontFamilyOfValue(String? value) {
  if (value == null || value.isEmpty || value == kSystemFontValue) return null;
  return value;
}

/// 字体族名 → 偏好值（`null` → `system`）。
String fontValueOfFamily(String? family) =>
    (family == null || family.isEmpty) ? kSystemFontValue : family;

/// 字体候选（M14 / FR-65 / BR-65.4）。
@immutable
class FontOption {
  const FontOption(this.label, this.family);

  /// 呈现名（中文名 + 族名，如「微软雅黑（Microsoft YaHei）」）。
  final String label;

  /// Flutter `fontFamily` 族名；`null` = 跟随系统。
  final String? family;

  bool get isSystemDefault => family == null;
}

/// 「跟随系统」（两种字体列表的公共首项）。
const FontOption kSystemFontOption = FontOption('跟随系统（平台默认）', null);

/// **界面字体**候选：不含「等宽」。
///
/// 源码模式与代码块**恒为等宽**，不由外观设置决定（BR-65.2），故不给界面字体提供等宽项。
List<FontOption> uiFontOptions(TargetPlatform platform) => _candidates(platform);

/// **笔记正文字体**候选：在公共候选之外多一项「等宽」（供需要等宽排版的用户）。
List<FontOption> bodyFontOptions(TargetPlatform platform) => <FontOption>[
      ..._candidates(platform),
      _monoFontOption(platform),
    ];

List<FontOption> _candidates(TargetPlatform platform) => switch (platform) {
      TargetPlatform.windows => const <FontOption>[
          kSystemFontOption,
          FontOption('微软雅黑（Microsoft YaHei）', 'Microsoft YaHei'),
          FontOption('微软雅黑 Light（Microsoft YaHei Light）',
              'Microsoft YaHei Light'),
          FontOption('等线（DengXian）', 'DengXian'),
          FontOption('宋体（SimSun）', 'SimSun'),
          FontOption('黑体（SimHei）', 'SimHei'),
          FontOption('楷体（KaiTi）', 'KaiTi'),
          FontOption('仿宋（FangSong）', 'FangSong'),
        ],
      TargetPlatform.macOS => const <FontOption>[
          kSystemFontOption,
          FontOption('苹方-简（PingFang SC）', 'PingFang SC'),
          FontOption('宋体-简（Songti SC）', 'Songti SC'),
          FontOption('楷体-简（Kaiti SC）', 'Kaiti SC'),
          FontOption('黑体-简（Heiti SC）', 'Heiti SC'),
        ],
      TargetPlatform.iOS => const <FontOption>[
          kSystemFontOption,
          FontOption('苹方（PingFang SC）', 'PingFang SC'),
          FontOption('宋体（Songti SC）', 'Songti SC'),
          FontOption('楷体（Kaiti SC）', 'Kaiti SC'),
          FontOption('无衬线（sans-serif）', 'sans-serif'),
          FontOption('衬线（serif）', 'serif'),
        ],
      TargetPlatform.android => const <FontOption>[
          kSystemFontOption,
          FontOption('无衬线（sans-serif）', 'sans-serif'),
          FontOption('衬线（serif）', 'serif'),
        ],
      TargetPlatform.linux ||
      TargetPlatform.fuchsia =>
        const <FontOption>[
          kSystemFontOption,
          FontOption('思源黑体（Noto Sans CJK SC）', 'Noto Sans CJK SC'),
          FontOption('思源宋体（Noto Serif CJK SC）', 'Noto Serif CJK SC'),
          FontOption('文泉驿微米黑（WenQuanYi Micro Hei）',
              'WenQuanYi Micro Hei'),
          FontOption('DejaVu Sans', 'DejaVu Sans'),
        ],
    };

FontOption _monoFontOption(TargetPlatform platform) => switch (platform) {
      TargetPlatform.windows => const FontOption('等宽（Consolas）', 'Consolas'),
      TargetPlatform.macOS => const FontOption('等宽（Menlo）', 'Menlo'),
      TargetPlatform.linux => const FontOption(
          '等宽（DejaVu Sans Mono）', 'DejaVu Sans Mono'),
      _ => const FontOption('等宽（monospace）', 'monospace'),
    };

/// 当前值在候选里的呈现名；找不到时回退为族名本身（并在 UI 标注「不可用（已回退）」）。
String fontOptionLabel(String? family, Iterable<FontOption> options) {
  if (family == null || family.isEmpty) return kSystemFontOption.label;
  for (final option in options) {
    if (option.family == family) return option.label;
  }
  return family;
}
