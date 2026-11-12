/// 附件「保存到本地 / 本机」的共享类型与文件名规整（FR-117 / BR-117）。
///
/// 为什么结果不是布尔：保存有**六种**需要区别对待的结局——成功、浏览器已开始下载、
/// 用户取消、平台不支持、本机无字节、失败。布尔会把「用户主动取消」显示成错误，
/// 也会把「本机没有文件管理器」伪装成「平台没实现」（与 `ExternalOpenResult` 同一取向）。
library;

/// 保存附件副本的六态结果。
enum AttachmentSaveOutcome {
  /// 已写入用户选定的路径（桌面三平台 / Android / iOS）。
  saved,

  /// 浏览器已开始下载（Web）。
  startedDownload,

  /// 用户在系统对话框取消（不提示、不落文件）。
  cancelled,

  /// 平台没有可用的保存能力（无壳层 / 通道缺失）。
  unsupported,

  /// 本机没有字节，且当前未连接服务端（无法按需下载）。
  noData,

  /// 已尝试保存，但落盘 / 写盘过程出错。
  failed,
}

/// [AttachmentSaveOutcome] 的载体，同时带回可展示的保存位置。
class AttachmentSaveResult {
  const AttachmentSaveResult(this.outcome, {this.location});

  final AttachmentSaveOutcome outcome;

  /// 可展示的保存位置：桌面为**完整路径**；Android / iOS 为 null
  /// （`file_picker` 返回的是拼出来的 `Downloads/<名>`，可能与实际所选位置不符）；
  /// Web 为 null（下载由浏览器接管）。
  final String? location;

  bool get isSaved =>
      outcome == AttachmentSaveOutcome.saved ||
      outcome == AttachmentSaveOutcome.startedDownload;
}

/// 规整**副本文件名**（只影响保存副本，不改附件名与正文引用，BR-117.5）。
///
/// 规则：
/// 1. 去掉路径成分（`/`、`\`）——防止 `../` 逃逸与 Windows 对话框拒绝；
/// 2. 替换 Windows 保留字符 `< > : " | ? *` 与控制字符为 `_`；
/// 3. 去掉首尾空白与**结尾点号**（Windows 不允许文件名以点结尾）；
/// 4. 规整后为空 / `.` / `..` → 回退 `attachment`；
/// 5. 过长（>120 字符）时截断 stem、保留扩展名（Windows 单段名上限 255）。
///
/// 纯函数：宿主机单测可直接断言，不依赖任何平台插件。
String sanitizeAttachmentFilename(String name) {
  // 末尾带分隔符（`a/`）时取**最后一个非空段**，而不是空串。
  final parts = name
      .split(RegExp(r'[\\/]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  var base = parts.isEmpty ? '' : parts.last;
  base = base.replaceAll(RegExp(r'[<>:"|?*\x00-\x1f]'), '_');
  // 只去结尾的点 / 空白：`报告 .pdf` 里的空格不是结尾空白，保留。
  base = base.replaceFirst(RegExp(r'[. ]+$'), '');
  if (base.isEmpty || base == '.' || base == '..') return 'attachment';

  const maxLength = 120;
  if (base.length > maxLength) {
    final dot = base.lastIndexOf('.');
    final hasExtension = dot > 0 && base.length - dot <= 12;
    final extension = hasExtension ? base.substring(dot) : '';
    final stem = hasExtension ? base.substring(0, dot) : base;
    final keep = maxLength - extension.length;
    if (keep > 0) {
      base = '${stem.substring(0, keep)}$extension';
    }
  }
  return base;
}
