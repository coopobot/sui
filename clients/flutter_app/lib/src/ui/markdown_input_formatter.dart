import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart';

/// **格式模式**的「语法字符自动转义」输入格式化器（M15 / FR-78 / BR-78.1\~78.5）。
///
/// ## 口径
///
/// 格式模式下**用户键入**一个会改变 Markdown 语法树的 ASCII 标点时，落到**正本**的字面量
/// 应当是该字符的**转义形式**（`\x`）——转义序列本身是标准 Markdown 的字面表达，正本仍是
/// 标准 Markdown（守 BR-23.1）。判定与产出全部委托给 [EditorFormat.escapeForTyping]：
/// 本类只负责「在 Flutter 的写入接缝上把它接上」，**不自造第二套规则**。
///
/// ## 三类必须原样放行的情形
///
/// 1. **IME 组合期**（`composing.isValid && !composing.isCollapsed`）：中文拼音 / 日文假名
///    上屏过程中会反复改写文本，此刻插入反斜杠会把组合串打断（FR-78 明示）。
/// 2. **非单字符插入**：删除、选区替换、粘贴、程序化写入（撤销 / 重做 / 工具栏指令）一律
///    原样返回——粘贴有自己的安全插入链路（[EditorFormat.escapePlainText] / 富文本转换），
///    在此再转义一次就是**二次转义**（BR-78.5）。
/// 3. **不在格式模式**：源码模式的 [TextField] **不挂**本格式化器（所见即正本，FR-77），
///    由调用方决定挂载与否；本类不自带模式判断。
///
/// ## 偏移契约
///
/// 转义把 1 个码元变成 2 个码元，故光标必须**右移 1** 才能停在用户刚输入字符的右侧
/// （否则光标会被留在反斜杠与字符之间，下一次输入就插到了转义序列中间）。
class MarkdownSyntaxEscapeFormatter extends TextInputFormatter {
  /// 创建一个格式化器。
  ///
  /// [inTableCell] 为 true 表示目标是**表格单元格**（行内语境）：跳过全部**行首敏感**
  /// 判定，且 `|` 不在此转义——`|` 由 `EditorFormat.setTableCell` 提交时的 `escapeTableCell`
  /// 统一处理，两处都转义会产出 `\\|`（双重转义，BR-44.4 / FR-78）。
  const MarkdownSyntaxEscapeFormatter({this.inTableCell = false});

  /// 是否作用于表格单元格内的文本框（见类文档）。
  final bool inTableCell;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // ① IME 组合期：原样放行（否则中文 / 日文上屏被打断）。
    final composing = newValue.composing;
    if (composing.isValid && !composing.isCollapsed) return newValue;

    // ② 只处理**单字符插入**：新旧选区都必须折叠且有效，且长度恰好 +1。
    final oldSel = oldValue.selection;
    final newSel = newValue.selection;
    if (!oldSel.isValid || !oldSel.isCollapsed) return newValue;
    if (!newSel.isValid || !newSel.isCollapsed) return newValue;
    if (newValue.text.length != oldValue.text.length + 1) return newValue;

    final caret = newSel.start;
    final at = caret - 1;
    if (at < 0 || caret > newValue.text.length) return newValue;
    // 防御：确认这确实是「在 [at] 处插入 1 个码元」，而不是其它改写（如末尾追加 + 选区前移）。
    if (oldValue.text !=
        newValue.text.substring(0, at) + newValue.text.substring(caret)) {
      return newValue;
    }

    final typed = newValue.text.substring(at, caret);
    final escaped = EditorFormat.escapeForTyping(
      oldValue.text,
      at,
      typed,
      inTableCell: inTableCell,
    );
    if (escaped == typed) return newValue;

    // ③ 落到正本的是转义形式；光标右移（保持停在刚键入字符的右侧）。
    final text =
        newValue.text.replaceRange(at, caret, escaped);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: caret + (escaped.length - typed.length),
      ),
      composing: TextRange.empty,
    );
  }
}
