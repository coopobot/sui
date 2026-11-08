/// 「用系统默认应用打开附件」的平台条件导入（FR-47 / BR-47.2 / FR-110）。
///
/// - 原生（桌面三平台）：把字节落系统临时文件后交系统壳层打开，并支持读回外部
///   编辑结果（回写用，BR-47.3）。
/// - Android：同一份临时文件 + 自研原生通道 `sui/platform.openFile`
///   （`FileProvider` content URI + `ACTION_VIEW`，见 ADR-040）；PDF / 图片 / 文本 /
///   音视频 / 压缩包由**系统默认应用**打开。只读授权，故**不做**外部编辑回写（BR-110.6）。
/// - iOS：无壳层、本轮无原生实现，返回「平台不支持」由调用方降级为内置预览。
/// - Web：无系统壳层，返回「平台不支持」，由调用方降级为内置预览（BR-47.5）。
///
/// 平台层只处理「文件系统 + 进程壳层 / 意图」这类必须 `dart:io` 的能力；字节来源与
/// 业务决策仍留在 `AppController`，保证 Web 与原生共用同一套上层逻辑。
library;

export 'attachment_open_result.dart';
export 'attachment_opener_web.dart'
    if (dart.library.io) 'attachment_opener_io.dart';
