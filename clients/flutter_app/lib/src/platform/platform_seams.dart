/// 平台能力的**测试接缝**（生产代码从不写入；见 ADR-028 / ADR-040）。
///
/// 为什么需要：打开外部网址（会真的拉起浏览器 / 走原生通道）、读剪贴板 HTML
/// （Windows CF_HTML / Android `ClipData`）与「用系统默认应用打开附件」（Android 走
/// `ACTION_VIEW`）都无法在单元测试里真跑。这里给出**可注入的覆盖点**，让 widget /
/// 单元测试既能断言「确实发起了打开请求」「分派到了正确平台」，也能喂入夹具；
/// **未注入时行为与生产完全一致**（与 Flutter 自身的
/// `debugDefaultTargetPlatformOverride` 同一范式）。
library;

import 'dart:typed_data';

import 'attachment_save.dart';

/// 覆盖「打开外部网址」的实现；非 null 时 `openExternalUrl` 直接委托给它
/// （协议白名单仍先行判定，故 `javascript:` 一类**不会**进到这里）。
Future<bool> Function(String url)? debugUrlOpenerOverride;

/// 覆盖「读剪贴板 HTML」的实现；非 null 时 `readClipboardHtml` 直接委托给它。
Future<String?> Function()? debugClipboardHtmlOverride;

/// 覆盖「读剪贴板位图」的实现（FR-123 / ADR-047）；非 null 时 `readClipboardImage`
/// 直接委托给它。测试用：注入 PNG / BMP 字节即可断言「只有位图」的整条粘贴链路，
/// 无需真实原生通道（生产代码从不写入）。
Future<Uint8List?> Function()? debugClipboardImageOverride;

/// 覆盖「当前操作系统」判定；非 null 时 `openExternally` 用它替代
/// `Platform.operatingSystem`。
///
/// 用途只有一个：在 Windows / Linux 宿主机上断言 **Android 分支**（真机形态的
/// `invokeMethod` 参数、三分返回值的映射），不必依赖 CI 跑 Android。
String? debugOpenTargetOsOverride;

/// 覆盖「Android 发 `ACTION_VIEW`」的实现；非 null 时不走 `sui/platform` 通道。
///
/// 返回值是原生侧的**返回码**（`ok` / `nohandler` / `error`，见 `MainActivity.kt`），
/// 便于逐条断言「返回码 → 提示文案」的映射（AC-643）。
Future<String?> Function({
  required String path,
  required String filename,
  required String mime,
})? debugAndroidOpenFileOverride;

/// 覆盖「临时文件落点」的**父目录**（路径字符串）；非 null 时在其下建 `sui_att_*`。
///
/// 测试用：Android 分支取 `cacheDir` 要经 path_provider 插件，宿主机单测里没有
/// 插件实现，注入一个真实临时目录即可把「落盘 → 发意图」整条链路跑通。
String? debugOpenTempBasePathOverride;

/// 覆盖「保存附件到本机」的**整个平台实现**（FR-117 / AC-667\~AC-673）。
///
/// 非 null 时 `saveAttachmentToDevice` 直接委托给它，用于 widget 测试断言：
/// 文件名是否已规整、字节是否与附件一致、UI 是否按六态结果给提示。
Future<AttachmentSaveResult> Function({
  required String filename,
  required Uint8List bytes,
})? debugAttachmentSaveOverride;

/// 覆盖桌面「另存为」返回的路径（**仅桌面分支**）。
///
/// 非 null 时不弹系统对话框：返回路径 → 走真实写盘（可断言文件内容）；
/// 返回 null → 模拟用户取消。宿主机单测据此覆盖「写盘 / 取消 / 失败」三条路径。
Future<String?> Function({required String filename})? debugSavePathOverride;
