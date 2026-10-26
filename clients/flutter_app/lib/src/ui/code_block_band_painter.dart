import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:note_core/note_core.dart';

/// 围栏代码块底色带的上下内边距（px，FR-81a / FR-93）。
///
/// 末围栏行的光标矩形底比行盒底部**高出约 1px**（M15 探针实测 0.67px），
/// 故内边距必须计入并留余量，否则最后一行会露出白边。
const double kCodeBlockBandPadding = 6;

/// 底色带圆角（px，与预览 `codeblockDecoration` 同源）。
const double kCodeBlockBandRadius = 6;

/// 底色带 `CustomPaint` 的关键节点（测试据此取绘制器与矩形）。
const ValueKey<String> kCodeBlockBandPainterKey =
    ValueKey<String>('sui-code-block-band-painter');

/// 格式模式下**围栏代码块块级底色带**的背景绘制器（FR-81a / BR-81.1 / FR-93 / FR-94）。
///
/// ## 为什么不是 inline `WidgetSpan`
///
/// `RenderParagraph` 的绘制顺序是「**先画整段文字、再画全部 inline 子 widget**」
/// （`paragraph.dart`：`_textPainter.paint(...)` → `paintInlineChildren(...)`）。
/// 因此 M15 那种「0×0 占位 widget + 溢出装饰盒」的写法，底色带会**盖住代码文字**
/// （实测：带内 `var a = 1;` 完全不可见）。改为在 `TextField` **背后**铺一层
/// `CustomPaint`：文字天然绘制在带之上，且带天然被编辑区 `ClipRect` 裁剪。
///
/// ## 几何口径
///
/// * 纵向：按 `RenderEditable.getLocalRectForCaret` 取**开围栏行行顶**与**闭合围栏行行底**
///   （未闭合块取文末），上下各加 [kCodeBlockBandPadding]；行几何已含滚动偏移，
///   滚动时无需另算（超出视口的部分由编辑区裁剪）。
/// * 横向：与**正文列宽（段落列宽）**对齐——`origin.dx` ~ `origin.dx + RenderEditable.width`，
///   两侧各留出编辑区左右内边距（16px）；**不再**铺到编辑区白底边缘（FR-93 / BR-93.2）。
/// * 色值 / 边框：由调用方从 `SuiAppearance.palette` 取 `codeSurface` / `codeBorder`
///   （与预览同源，BR-81.1）。
/// * 与段落左右对齐：代码块**不再**贴着编辑区边缘，左右各留 16px 内边距（用户口径：
///   「代码块左右应该空一点，跟段落对齐」）。
class CodeBlockBandPainter extends CustomPainter {
  CodeBlockBandPainter({
    required this.controller,
    required this.fieldKey,
    required this.inset,
    required this.enabled,
    required this.surface,
    required this.border,
    required this.textStyle,
    required this.textScaler,
    required Listenable repaint,
  }) : super(repaint: repaint);

  /// 正文控制器：取正本文本（`EditorFormat.fenceBlocks` 据此定位围栏块）。
  final TextEditingController controller;

  /// 正文 `TextField` 的 key：据此在元素树里找到 `RenderEditable` 取行几何，
  /// 并换算到绘制器坐标系。
  final GlobalKey fieldKey;

  /// 编辑区左右 / 上下内边距（px，= `kEditorBodyPadding`）：`TextField` 相对
  /// 绘制器原点的位移。
  final double inset;

  /// 是否绘制（格式模式 true、源码模式 false）。
  final bool enabled;

  /// 底色（`palette.codeSurface`）。
  final Color surface;

  /// 边框（`palette.codeBorder`）。
  final Color border;

  /// 正文基础样式（含笔记本字体覆盖 / 字号 / 行距）：行几何随它变化，故参与 `shouldRepaint`。
  final TextStyle textStyle;

  /// 系统文字缩放：同样影响行几何。
  final TextScaler textScaler;

  /// 最近一次绘制出的带矩形（**本绘制器坐标系**：原点 = 编辑区白底左上角）。
  ///
  /// 仅供测试断言之用（生产代码不读它）。
  @visibleForTesting
  List<Rect> debugBandRects = const <Rect>[];

  @override
  void paint(Canvas canvas, Size size) {
    debugBandRects = const <Rect>[];
    if (!enabled || size.isEmpty) return;
    final fieldBox = fieldKey.currentContext?.findRenderObject();
    final editable = _findRenderEditable(fieldKey.currentContext);
    if (fieldBox is! RenderBox || editable == null) return;
    if (!fieldBox.hasSize || !editable.hasSize) return;

    final blocks = EditorFormat.fenceBlocks(controller.text);
    if (blocks.isEmpty) return;

    // 正文起点相对绘制器原点的位移：编辑区内边距 + `TextField` 自身的内部留白。
    final origin =
        fieldBox.globalToLocal(editable.localToGlobal(Offset.zero)) +
            Offset(inset, inset);

    final rects = <Rect>[];
    for (final block in blocks) {
      final top = editable
          .getLocalRectForCaret(TextPosition(offset: block.start))
          .top;
      final bottom = editable
          .getLocalRectForCaret(TextPosition(offset: block.end))
          .bottom;
      if (!top.isFinite || !bottom.isFinite || bottom <= top) continue;
      final rect = Rect.fromLTRB(
        origin.dx,
        origin.dy + top - kCodeBlockBandPadding,
        origin.dx + editable.size.width,
        origin.dy + bottom + kCodeBlockBandPadding,
      );
      final rrect = RRect.fromRectAndRadius(
        rect.deflate(0.5),
        const Radius.circular(kCodeBlockBandRadius),
      );
      canvas.drawRRect(rrect, Paint()..color = surface);
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      rects.add(rect);
    }
    debugBandRects = List<Rect>.unmodifiable(rects);
  }

  @override
  bool shouldRepaint(CodeBlockBandPainter oldDelegate) =>
      oldDelegate.enabled != enabled ||
      oldDelegate.inset != inset ||
      oldDelegate.surface != surface ||
      oldDelegate.border != border ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.controller != controller ||
      oldDelegate.fieldKey != fieldKey;

  /// 在 [root] 的元素子树里找正文的 [RenderEditable]（`EditableText` 的渲染对象）。
  static RenderEditable? _findRenderEditable(BuildContext? root) {
    if (root is! Element) return null;
    RenderEditable? found;
    void visit(Element element) {
      if (found != null) return;
      final renderObject = element.renderObject;
      if (renderObject is RenderEditable) {
        found = renderObject;
        return;
      }
      element.visitChildElements(visit);
    }

    root.visitChildElements(visit);
    return found;
  }
}
