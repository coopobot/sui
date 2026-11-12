import 'dart:math' as math;

/// 大笔记「自动分块」的阈值判定（release 实测模型）。
///
/// 依据：`technology/design/low-level-design/editor-typing-latency-analysis.md` §10.3——
/// 单键成本 ≈ `0.93 × chars/1000 + 5.0e-5 × spans^1.81`（ms，release / 本机 / 微软雅黑）。
/// 达到 [triggerMs]（约一帧）即应切到「分块（块级虚拟化）编辑」。
///
/// `spans` 用 `EditorFormat.syntaxMarkers(text).length` 近似（与真实 span 数强相关）；
/// 它只在**加载笔记 / 文本外部变化**时算一次，不进按键路径。
class LargeNotePolicy {
  const LargeNotePolicy._();

  /// 触发阈值（ms / 键）：一帧（16.7 ms）。比 25 ms 更早切换，宁可用分块模式也不掉帧。
  static const double triggerMs = 16.7;

  /// 低于该字符数一律不触发（避免极短但密集的文档被误判）。
  static const int minChars = 4000;

  /// 每键成本的估计值（ms）。
  static double estimateMs({required int chars, required int spans}) {
    if (chars <= 0) return 0;
    final s = spans <= 0 ? 0.0 : math.pow(spans.toDouble(), 1.81).toDouble();
    return 0.93 * chars / 1000 + 5.0e-5 * s;
  }

  /// 是否应进入分块模式。
  static bool shouldSegment({required int chars, required int spans}) =>
      chars >= minChars &&
      estimateMs(chars: chars, spans: spans) >= triggerMs;
}
