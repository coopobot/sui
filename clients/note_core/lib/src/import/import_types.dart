import 'dart:typed_data';

/// M13（FR-60 / FR-61 / FR-62）批量导入本地文件 —— 公开类型。
///
/// 详细设计：technology/design/low-level-design/file-import.md §3.1；
/// 决策：ADR-024（客户端转换 + 内容指纹本机幂等）。
///
/// 本文件**不碰** `dart:io` / `dart:html` / Flutter：字节由平台层读入后经
/// [ImportSourceFile] 注入，相对资源经 [ResourceResolver] 回调解析（BR-60.9）。

/// 资源占位符：`\uE000<index>\uE001`（Unicode **私有使用区**，PUA）。
///
/// 正文里不可能自然出现这两个字符，故可安全地「整节点替换」（§6.9）：
/// 转换器把 `<img>` / `<a>` 等节点写成占位符，服务侧本地化后再整体替换成
/// `![alt](sui://<sha256>)` 或 `[text](url)`。
const String kResourcePlaceholderStart = '\u{E000}';
const String kResourcePlaceholderEnd = '\u{E001}';

/// 生成第 [index] 个资源占位符。
String resourcePlaceholder(int index) =>
    '$kResourcePlaceholderStart$index$kResourcePlaceholderEnd';

/// 可导入的源文件扩展名（小写，无点）。
///
/// 平台层的文件选择器过滤器与递归收集**都用它**，避免「选择器能选、服务却判不支持」
/// 的口径分裂（FR-60 / BR-60.9）；服务侧的扩展名过滤也取自这里（§4.1）。
const List<String> kImportSupportedExtensions = [
  'md',
  'markdown',
  'txt',
  'html',
  'htm',
];

/// 文件名是否为可导入类型（大小写不敏感）。
///
/// 取最后一个 `.` 之后的小写片段与 [kImportSupportedExtensions] 比对；
/// 无扩展名（含 `trailing.`）→ `false`。
bool isSupportedImportFileName(String fileName) {
  final normalized = fileName.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final base = slash < 0 ? normalized : normalized.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) return false;
  return kImportSupportedExtensions.contains(base.substring(dot + 1).toLowerCase());
}

/// 相对资源解析回调：给定 HTML 里的原始引用，返回字节；取不到返回 `null`（走降级）。
///
/// 平台层实现（`flutter_app` 的 `import_picker_io.dart`）按 basename 逐候选回退；
/// **Web 端恒为 `null`** → 相对资源一律降级（BR-60.9 / AC-248）。
typedef ResourceResolver = Future<Uint8List?> Function(String reference);

/// 一个待导入的源文件（平台层已把字节读入内存）。
class ImportSourceFile {
  const ImportSourceFile({
    required this.name,
    required this.bytes,
    this.pathHint = '',
    this.resolveResource,
  });

  /// 含扩展名的文件名（标题回退、报告用；BR-60.5：文件名**只作标题候选**）。
  final String name;

  /// 原始字节。
  final Uint8List bytes;

  /// 源位置提示（桌面端为绝对路径）；**仅用于诊断**，不参与任何路径构造。
  final String pathHint;

  /// 该文件所在目录的资源解析；Web 端为 `null`。
  final ResourceResolver? resolveResource;
}

/// 单项结果分类（BR-62.3：跳过 ≠ 失败）。
enum ImportOutcome {
  /// 已落库。
  success,

  /// 按业务规则跳过（重复 / 不支持 / 空 / 超限 / 索引页），**不算失败**。
  skipped,

  /// 处理失败（附可行动原因）。
  failed,
}

/// 跳过原因（报告需给「可行动」的口径）。
enum ImportSkipReason {
  /// 内容指纹已存在（BR-62.1）。
  duplicate,

  /// 扩展名不在集合内。
  unsupportedType,

  /// 转换后标题与正文皆空（BR-60.4）。
  empty,

  /// 单文件超过 `maxFileBytes`（BR-60.3）。
  tooLarge,

  /// 超出单批文件数（BR-60.3）。
  batchLimit,

  /// 印象笔记导出索引页（BR-61.10）。
  indexPage,
}

/// 资源大类：图片（`sui://` 引用为 `![alt](...)`）或链接/附件（`[text](...)`）。
enum ImportResourceKind { image, link }

/// 正文中的一个资源节点（占位符代表的整体）。
class ImportResourceRef {
  const ImportResourceRef({
    required this.index,
    required this.kind,
    required this.reference,
    this.alt = '',
    this.suggestedName = '',
    this.inlineBytes,
    this.width,
    this.remote = false,
  });

  /// 正文占位符序号（与 [resourcePlaceholder] 一致）。
  final int index;
  final ImportResourceKind kind;

  /// 原始引用（相对路径 / `data:` / `http(s):` …）。
  final String reference;

  /// 图片 `alt` 或链接文字（降级时保留，绝不丢字）。
  final String alt;

  /// 建议文件名（相对路径 basename / `data-` 推导 / 链接文字回退）。
  final String suggestedName;

  /// `data:` 已解码结果；其余为 `null`。
  final Uint8List? inlineBytes;

  /// 显式像素宽度（BR-61.5 / ADR-007）；非像素或缺失为 `null`。
  final int? width;

  /// `http(s)` 等远端 / 带 scheme 引用：保持 URL、**不下载**（FR-61 / AC-247）。
  final bool remote;
}

/// 转换产物：**一篇**待导入笔记（多节 HTML 会产出多篇）。
class ImportedDocument {
  const ImportedDocument({
    this.title = '',
    required this.markdown,
    this.resources = const [],
    this.warnings = const [],
  });

  /// 可为空 → 调用方按文件名回退（BR-61.9 的「文件名 (n)」已在转换器内回退）。
  final String title;

  /// 含资源占位符的 Markdown（本地化后占位符必须全部消失，§7）。
  final String markdown;

  final List<ImportResourceRef> resources;

  /// 如「编码可能不正确」（BR-61.7 / AC-251）。
  final List<String> warnings;
}

/// 单条报告项。
class ImportItemResult {
  const ImportItemResult({
    required this.fileName,
    this.title = '',
    required this.outcome,
    this.skipReason,
    this.failureReason = '',
    this.noteId = '',
    this.localizedResources = 0,
    this.unlocalizedResources = 0,
    this.warning = '',
  });

  final String fileName;
  final String title;
  final ImportOutcome outcome;
  final ImportSkipReason? skipReason;

  /// `outcome == failed` 时的**可行动**原因（BR-62.3）。
  final String failureReason;

  /// `outcome == success` 时非空。
  final String noteId;

  final int localizedResources;
  final int unlocalizedResources;

  /// 编码降级等（BR-61.7）。
  final String warning;
}

/// 一次导入的汇总报告。
class ImportReport {
  const ImportReport({
    this.items = const [],
    this.cancelled = false,
    this.startedAt,
    this.finishedAt,
    this.targetNotebookLabel = '',
  });

  /// 逐项明细（BR-61.9：多节文件按**笔记**逐条列出，每条的 [ImportItemResult.fileName]
  /// 都是来源文件名）。
  final List<ImportItemResult> items;

  /// 用户中途取消（已导入的保留，AC-238）。
  final bool cancelled;

  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// 目标笔记本展示名（「未分组」或笔记本名）；仅用于报告抬头。
  final String targetNotebookLabel;

  int get successCount =>
      items.where((i) => i.outcome == ImportOutcome.success).length;
  int get skippedCount =>
      items.where((i) => i.outcome == ImportOutcome.skipped).length;
  int get failedCount =>
      items.where((i) => i.outcome == ImportOutcome.failed).length;

  /// 未本地化资源总数 = 各项之和（§9 收尾口径）。
  int get unlocalizedCount =>
      items.fold(0, (sum, i) => sum + i.unlocalizedResources);

  /// 复制到剪贴板的报告文本（§11 格式）。
  ///
  /// **只含**文件名、推导标题与计数，**不含笔记正文**（BR-62.4）。
  String toClipboardText() {
    final buf = StringBuffer()
      ..writeln('随手记 Sui · 导入报告')
      ..writeln('导入到：${targetNotebookLabel.isEmpty ? '未分组' : targetNotebookLabel}'
          '    时间：${(finishedAt ?? DateTime.now()).toIso8601String()}')
      ..writeln('成功 $successCount · 跳过 $skippedCount · 失败 $failedCount '
          '· 未本地化资源 $unlocalizedCount');
    if (cancelled) buf.writeln('（已取消：未处理完的文件不再导入，已导入的保留）');
    buf.writeln('---');
    for (final i in items) {
      buf.writeln(_line(i));
    }
    return buf.toString();
  }

  static String _line(ImportItemResult i) {
    final title = i.title.isEmpty ? '' : ' → ${i.title}';
    switch (i.outcome) {
      case ImportOutcome.success:
        final res = i.localizedResources == 0
            ? ''
            : '（资源本地化 ${i.localizedResources}）';
        final warn = i.warning.isEmpty ? '' : '（${i.warning}）';
        return '[成功] ${i.fileName}$title$res$warn';
      case ImportOutcome.skipped:
        final reason = switch (i.skipReason) {
          ImportSkipReason.duplicate => '重复',
          ImportSkipReason.unsupportedType => '不支持的类型',
          ImportSkipReason.empty => '空文件',
          ImportSkipReason.tooLarge => '超过单文件大小上限',
          ImportSkipReason.batchLimit => '超过单批文件数上限',
          ImportSkipReason.indexPage => '索引页',
          null => '跳过',
        };
        return '[跳过·$reason] ${i.fileName}';
      case ImportOutcome.failed:
        return '[失败] ${i.fileName}：'
            '${i.failureReason.isEmpty ? '未知原因' : i.failureReason}';
    }
  }
}

/// 进度：**按文件计**（多节文件只计 1 次，BR-61.9）。
class ImportProgress {
  const ImportProgress({
    required this.processed,
    required this.total,
    required this.currentName,
  });

  final int processed;
  final int total;

  /// 当前（或刚处理完）的文件名。
  final String currentName;

  double get ratio => total <= 0 ? 1 : processed / total;
}

/// 导入限额与行为开关（BR-60.3）。
class ImportOptions {
  const ImportOptions({
    this.maxFileBytes = 20 * 1024 * 1024,
    this.maxFiles = 500,
  });

  /// 单文件上限（20 MiB）；资源单文件同样受此约束。
  final int maxFileBytes;

  /// 单批文件数上限（500）。
  final int maxFiles;
}
