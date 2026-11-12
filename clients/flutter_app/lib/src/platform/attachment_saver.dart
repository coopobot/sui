/// 附件「保存到本地 / 本机」的平台条件导入（FR-117 / BR-117）。
///
/// - 桌面三平台：系统「另存为」对话框选路径，**由应用自己写盘**
///   （`file_picker` 在桌面只返回路径、忽略 `bytes`，见 ADR-042 决策 1）。
/// - Android / iOS：系统「创建文档」选择器（`ACTION_CREATE_DOCUMENT`），
///   由插件把字节写入用户选定的 URI，应用不再二次写盘。
/// - Web：`Blob` + `a[download]`，用 SDK 自带 `dart:js_interop` 触发浏览器下载。
///
/// 平台层只做「文件系统 / 系统对话框 / 浏览器下载」；字节来源与业务决策留在
/// `AppController`（与 `attachment_opener.dart` 同一分层）。
library;

export 'attachment_save.dart';
export 'attachment_saver_web.dart'
    if (dart.library.io) 'attachment_saver_io.dart';
