import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Windows 桌面端**中文输入法候选框跟随光标**（v0.17.1 / FR-98 / ADR-035）。
///
/// ## 为什么需要这个补丁
///
/// Windows 引擎的 `TextInputManager` 用 **`TextInput.setMarkedTextRect`** 携带的矩形
/// 定位输入法的「组合窗口」，候选框出现在该矩形下方；它**没有实现**
/// `TextInput.setCaretRect`（本机 Flutter 3.47.5 引擎的 `flutter_windows.dll` /
/// `.pdb` 里都查不到该方法，只有 `SetMarkedTextRect`）。
///
/// 而框架侧 `EditableText._updateComposingRectIfNeeded()` 在**没有组合区**时回退为
/// 「`TextPosition(offset: 0)` 的光标矩形」，也就是**正文第一个字**的位置。于是：
/// 在一篇长笔记中间敲第一个拼音时，引擎把组合窗口摆在正文开头（编辑区左上角），
/// 候选框因此「不在光标附近」；要等组合区建立后框架下一帧把矩形挪到光标，候选框
/// 才跟着走 —— 输入单个汉字时，候选框往往整段生命期都停在左上角。
///
/// ## 做法
///
/// 每帧结束后（`Future.microtask`，排在框架自身的 post-frame 回调之后）把**当前聚焦
/// 输入框的光标矩形**用**同一条** `TextInput.setMarkedTextRect` 回填一次。引擎的组合
/// 窗口因而始终停在光标上：候选框无论在哪一帧弹出都贴着光标。
///
/// 边界：
/// * **只在 Windows 桌面**启用（macOS / Linux / 移动端 / Web 无此引擎行为，不做无谓的通道调用）；
/// * **不改写任何输入内容**、不碰编辑值，只补一个位置提示；
/// * 通道失败（引擎未实现 / 窗口正销毁）静默忽略——这是位置增强，不是输入的前提。
class ImeCaretAnchor {
  ImeCaretAnchor._();

  static bool _started = false;

  /// 上一次回填的输入框身份 / 值 / 矩形（FR-99 / BR-99.5）：全部相同则跳过通道调用。
  ///
  /// 只节流**重复**消息，不改变 ADR-035 的「晚于框架、贴光标」时序与字段。
  static EditableTextState? _lastEditable;
  static TextSelection? _lastSelection;
  static TextRange? _lastComposing;
  static int? _lastTextLength;
  static Rect? _lastRect;

  /// 本平台是否需要该补丁（仅 Windows 桌面）。
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 启动逐帧回填。重复调用无副作用；在 `main()` 里调用一次即可。
  static void start() {
    if (_started || !supported) return;
    _started = true;
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  /// 仅供测试：复位启动标记。
  @visibleForTesting
  static void debugReset() {
    _started = false;
    _lastEditable = null;
    _lastSelection = null;
    _lastComposing = null;
    _lastTextLength = null;
    _lastRect = null;
  }

  /// 仅供测试：立刻回填一次（不依赖帧与定时器）。
  @visibleForTesting
  static bool debugReportCaretRect() => _reportCaretRect();

  static void _onFrame(Duration _) {
    // 微任务在**本帧全部 post-frame 回调**之后、下一个事件循环任务之前执行：
    // 框架先发出它自己的 `setMarkedTextRect`（无组合区时是 offset-0 的矩形），
    // 我们随后覆盖它 —— 引擎侧最后一次写入即真实光标矩形。
    Future<void>.microtask(_reportCaretRect);
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  static bool _reportCaretRect() {
    final EditableTextState? editable = _focusedEditableText();
    if (editable == null) return false;
    // 只读 / 预览态没有输入连接：此时发消息会被引擎当成「没有客户端」而报错。
    if (editable.widget.readOnly) return false;
    final RenderEditable renderEditable = editable.renderEditable;
    if (!renderEditable.attached) return false;
    final TextSelection selection = editable.textEditingValue.selection;
    if (!selection.isValid) return false;

    // 用 `extentOffset`（键入落点）而不是 `start`：反向选区里光标在 extent 一侧，
    // 候选框应当贴着真正会插入文字的位置。
    final Rect rect = renderEditable.getLocalRectForCaret(
      TextPosition(offset: selection.extentOffset),
    );
    // v0.17.2（FR-99 / BR-99.5）：输入框 / 选区 / 组合区 / 文本长度 / 矩形都没变时
    // 不再每帧发通道消息（空闲 60 次/秒的调用是长会话卡顿的来源之一）。
    final value = editable.textEditingValue;
    if (identical(_lastEditable, editable) &&
        _lastSelection == selection &&
        _lastComposing == value.composing &&
        _lastTextLength == value.text.length &&
        _lastRect == rect) {
      return false;
    }
    _lastEditable = editable;
    _lastSelection = selection;
    _lastComposing = value.composing;
    _lastTextLength = value.text.length;
    _lastRect = rect;
    // 与框架 `TextInputConnection.setComposingRect` **完全相同的通道、方法与字段**
    // （本地坐标；引擎用 `setEditableSizeAndTransform` 自行换算到视图坐标），
    // 因此不需要任何平台侧代码，也不会与引擎的坐标系产生分歧。
    unawaited(
      SystemChannels.textInput
          .invokeMethod<void>('TextInput.setMarkedTextRect', <String, dynamic>{
        'width': rect.width,
        'height': rect.height,
        'x': rect.left,
        'y': rect.top,
      })
          .catchError((Object _) {
        // 忽略：通道不可用只是失去位置增强，输入本身不受影响。
      }),
    );
    return true;
  }

  static EditableTextState? _focusedEditableText() {
    final BuildContext? context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    return context.findAncestorStateOfType<EditableTextState>();
  }
}
