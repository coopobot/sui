import 'package:flutter/material.dart';

import 'font_catalog.dart';

/// 量测接缝：返回指定族名在同字号下的布局宽度（可注入，便于单测）。
typedef FontMeasurer = double Function(String? family, String sample);

/// 字体**运行时可用性探测**（M14 / FR-65 / BR-65.3）。
///
/// **为什么需要**：Flutter 对**不存在的字体族名静默回退**——不报错、也不提示，
/// 用户看到的是「选了没反应」。故候选清单必须经**可用性自检**后再呈现。
///
/// **判据（确定性）**：同字号、同一段中英混排文本下，分别以
/// ①目标族名、②**哨兵族名**（必然不存在）布局并比较宽度——
/// **宽度不同 ⇒ 被系统解析（可用）；宽度相同 ⇒ 视为不可用**（等价于落回同一默认字体）。
///
/// 已知局限：族名存在但度量与默认字体**完全一致**时会误判为不可用（该字体不列出）——
/// 这是**可接受的**保守方向（不会让用户「选了没反应」）。
class FontAvailability {
  FontAvailability({FontMeasurer? measurer})
      : _measure = measurer ?? measureTextWidth;

  /// 哨兵族名：正常系统上**必然不存在**。
  static const String sentinelFamily = '__sui_missing_font__';

  /// 量测样本：中英混排，覆盖「只有中文字形差异」的情形。
  static const String sampleText = '永Suì随手记Ag';

  /// 量测字号（与正文默认字号一致）。
  static const double sampleFontSize = 15;

  final FontMeasurer _measure;
  final Map<String, bool> _cache = <String, bool>{};

  /// 该族名在本机是否可用（结果缓存于本次会话）。
  bool isAvailable(String family) =>
      _cache.putIfAbsent(family, () => _probe(family));

  bool _probe(String family) {
    final target = _measure(family, sampleText);
    final sentinel = _measure(sentinelFamily, sampleText);
    return (target - sentinel).abs() > 0.01;
  }

  /// 过滤候选：**跟随系统恒保留**（不需要字体文件），其余按探测结果。
  List<FontOption> available(Iterable<FontOption> options) => <FontOption>[
        for (final option in options)
          if (option.family == null || isAvailable(option.family!)) option,
      ];

  /// 该族名是否可用（`null` = 跟随系统，恒可用）。
  bool isOptionUsable(String? family) =>
      family == null || family.isEmpty || isAvailable(family);

  @visibleForTesting
  void clearCache() => _cache.clear();

  // ---- 进程内单例 + 测试注入 ----

  static FontAvailability? _instance;

  /// 应用内共享实例（会话内缓存探测结果，避免每次打开设置都重量测）。
  static FontAvailability get instance => _instance ??= FontAvailability();

  @visibleForTesting
  static set instanceForTesting(FontAvailability? value) => _instance = value;
}

/// 默认量测实现：[TextPainter] 单行布局取宽。
double measureTextWidth(String? family, String sample) {
  final painter = TextPainter(
    text: TextSpan(
      text: sample,
      style: TextStyle(
        fontFamily: family,
        fontSize: FontAvailability.sampleFontSize,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
