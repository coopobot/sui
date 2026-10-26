import 'import_types.dart';

/// M13 文本链路（`.md` / `.markdown` / `.txt`）—— 详细设计 §5。
///
/// 两条链路的**口径完全不同**，故分成两个函数，不做统一抽象：
/// * `.md` / `.markdown`：BR-61.1 **逐字节保真**（不换行统一、不空白规整、不转义）；
/// * `.txt`：BR-61.2 **四项空白规整**（可解释、不算丢字）。

/// 由文件名推导标题：去扩展名 + 去首尾空白（BR-60.5）。
///
/// 只取**最后一段**（`a/b/c.md` → `c`），因为文件名是唯一允许的标题来源，
/// 目录路径既不参与标题也不参与任何路径构造。
String titleFromFileName(String fileName) {
  final normalized = fileName.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final base = slash < 0 ? normalized : normalized.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  final stem = dot <= 0 ? base : base.substring(0, dot);
  return stem.trim();
}

/// 文件扩展名（小写，不含点）；无扩展名返回空串。
String extensionOf(String fileName) {
  final normalized = fileName.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final base = slash < 0 ? normalized : normalized.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// `.md` / `.markdown`（BR-61.1 / AC-241）。
///
/// * `title`：首个**非空行**匹配 `^#\s+(.+)$` → 取该文本；否则 [titleFromFileName]。
/// * `markdown`：**原样**——特别注意**不因标题提取而删掉那行 H1**。
/// * [degraded]（可选）：解码阶段发生「非法字节 → 替换字符」降级时置真，
///   转换产物据此在报告里标注「编码可能不正确」（BR-61.7 / AC-251）。
ImportedDocument parseMarkdownSource(
  String text,
  String fileName, {
  bool degraded = false,
}) {
  final warnings = degraded ? const ['编码可能不正确'] : const <String>[];
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    final m = RegExp(r'^#\s+(.+)$').firstMatch(line);
    if (m != null) {
      return ImportedDocument(
        title: m.group(1)!.trim(),
        markdown: text,
        warnings: warnings,
      );
    }
    break; // 只看首个非空行
  }
  return ImportedDocument(
    title: titleFromFileName(fileName),
    markdown: text,
    warnings: warnings,
  );
}

/// `.txt`（BR-61.2 / AC-242）：四项空白规整，**不**转义 Markdown 特殊字符、
/// **不**折叠段内单换行、**不**删除任何可见字符。
///
/// ① `\r\n` / `\r` → `\n`；② 去每行行尾空白；③ 连续空白行折叠为 **1** 个空行；
/// ④ 去首尾空行并保证结尾**恰好一个** `\n`。
ImportedDocument parsePlainTextSource(
  String text,
  String fileName, {
  bool degraded = false,
}) =>
    ImportedDocument(
      title: titleFromFileName(fileName),
      markdown: normalizePlainText(text),
      warnings: degraded ? const ['编码可能不正确'] : const <String>[],
    );

/// **只做换行归一**（`\r\n` / `\r` → `\n`），不做任何空白规整。
///
/// 用途与 [normalizePlainText] **不同**：本函数服务于**编辑器内的粘贴**（M15 / FR-77 / BR-77.3）
/// ——Windows 剪贴板是 CRLF 的真实注入路径，而 CRLF 会让格式模式的行级识别（任务项 / 分割线 /
/// setext）整行失配，故粘贴必须先统一换行；但粘贴**不得**顺带做「逐行 rstrip / 折叠空行 /
/// 去首尾空行 / 补结尾换行」——那会在**行内粘贴一个词**时凭空多出一个换行，属可见缺陷。
String normalizeLineEndings(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// [parsePlainTextSource] 的规整主体（四项），单独抽出便于复用与测断言。
///
/// **导入专用**：含「逐行 rstrip / 折叠连续空行 / 去首尾空行 / 结尾恰好一个 `\n`」四项规整，
/// 与**粘贴**口径不同（粘贴只做换行归一，见 [normalizeLineEndings]）。
String normalizePlainText(String text) {
  // ① 换行统一。
  final unified = normalizeLineEndings(text);
  // ② 行尾空白。
  final trimmed = unified.split('\n').map(_rstrip).toList();
  // ③ 连续的空行折叠为 1 个空行（即任意长度空行串只保留一个空行）。
  final collapsed = <String>[];
  for (final line in trimmed) {
    if (line.isEmpty && collapsed.isNotEmpty && collapsed.last.isEmpty) {
      continue;
    }
    collapsed.add(line);
  }
  // ④ 去首尾空行 + 结尾恰好一个 \n。
  var start = 0;
  var end = collapsed.length;
  while (start < end && collapsed[start].isEmpty) {
    start++;
  }
  while (end > start && collapsed[end - 1].isEmpty) {
    end--;
  }
  if (start >= end) return '';
  return '${collapsed.sublist(start, end).join('\n')}\n';
}

/// 去行尾空白（空格 / 制表 / 其它空白，但**保**行首缩进）。
String _rstrip(String line) =>
    line.replaceFirst(RegExp(r'[ \t\u00a0\u3000]+$'), '');
