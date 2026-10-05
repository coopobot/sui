/// 「用系统默认应用打开附件」的平台条件导入（FR-47 / BR-47.2）。
///
/// - 原生（桌面 / 移动）：把字节落系统临时文件后交系统壳层打开，并支持读回外部
///   编辑结果（回写用，BR-47.3）。
/// - Web：无系统壳层，返回 null，由调用方降级为内置预览 / 下载（BR-47.5）。
///
/// 平台层只处理「文件系统 + 进程壳层」这类必须 `dart:io` 的能力；字节来源与业务
/// 决策仍留在 `AppController`，保证 Web 与原生共用同一套上层逻辑。
library;

export 'attachment_opener_web.dart'
    if (dart.library.io) 'attachment_opener_io.dart';
