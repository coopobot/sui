import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// 正文焦点节点 + 辅助功能焦点丢失门禁（BUG 修复）。
///
/// ## 缺陷
///
/// 格式模式按 `Ctrl+Shift+C`（勾选框）后，正文被**静默取消聚焦**：光标消失、
/// 后续键输入全部丢弃，必须重新点正文才能继续输入。
///
/// 实测调用栈（Windows，v0.17.2）：
/// ```
/// _TextFieldState.build.<anonymous closure>      material/text_field.dart:1660
/// SemanticsAnnotationsMixin._performDidLoseAccessibilityFocus
/// SemanticsOwner.performAction
/// RendererBinding.performSemanticsAction
/// SemanticsBinding._handleSemanticsActionEvent
/// PlatformDispatcher._dispatchSemanticsAction
/// ```
/// Flutter 在**桌面端**把 `TextField` 的「辅助功能丢失焦点」接到
/// `focusNode.unfocus()`。而 Windows 上 UIA 辅助功能焦点与键盘焦点彼此独立：
/// 正文一变化，语义树重建，平台随之派发 `didLoseAccessibilityFocus`，正文的
/// 键盘焦点就被误摘（移动端的辅助功能焦点就是输入焦点，故该联动只在桌面端有害）。
///
/// ## 修法（否决，而非事后补回）
///
/// [A11yFocusGate] 在平台派发 `didLoseAccessibilityFocus` 的瞬间置位；本节点在
/// `unfocus()` 里看到该标志即**忽略这次取消聚焦**。键盘焦点、输入连接、IME 组合
/// 态全程不受扰动；其它一切 `unfocus`（点空白、切窗口、弹框、命令交还焦点）照旧。
class EditorFocusNode extends FocusNode {
  EditorFocusNode() : super(debugLabel: 'noteEditorContent');

  @override
  void unfocus({UnfocusDisposition disposition = UnfocusDisposition.scope}) {
    if (A11yFocusGate.inLoseFocusDispatch && _isDesktop) {
      // 否决：桌面端「辅助功能焦点丢失」不得联动键盘焦点（见类注释的缺陷说明）。
      return;
    }
    super.unfocus(disposition: disposition);
  }

  static bool get _isDesktop => switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.linux ||
        TargetPlatform.macOS =>
          true,
        _ => false,
      };
}

/// 平台语义动作的门禁：只在 `didLoseAccessibilityFocus` 派发期间置位。
///
/// 包一层 [PlatformDispatcher.onSemanticsActionEvent]（框架的 `SemanticsBinding`
/// 自己也是这么挂载的公共接缝），链式调用上一任 handler，`try/finally` 保证标志
/// 绝不残留。安装幂等，由 [EditorFocusNode] 首次随编辑器挂载时调用。
class A11yFocusGate {
  A11yFocusGate._();

  static bool _inLoseFocusDispatch = false;
  static bool _installed = false;

  static bool get inLoseFocusDispatch => _inLoseFocusDispatch;

  static void install() {
    if (_installed) return;
    _installed = true;
    final previous =
        WidgetsBinding.instance.platformDispatcher.onSemanticsActionEvent;
    WidgetsBinding.instance.platformDispatcher.onSemanticsActionEvent =
        (SemanticsActionEvent event) {
      final isLose = event.type == SemanticsAction.didLoseAccessibilityFocus;
      if (isLose) _inLoseFocusDispatch = true;
      try {
        previous?.call(event);
      } finally {
        if (isLose) _inLoseFocusDispatch = false;
      }
    };
  }
}
