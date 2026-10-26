/// 平台能力的**测试接缝**（生产代码从不写入；见 ADR-028）。
///
/// 为什么需要：打开外部网址（会真的拉起浏览器 / 走原生通道）与读剪贴板 HTML
/// （Windows CF_HTML / Android `ClipData`）都无法在单元测试里真跑。这里给出两个
/// **可注入的覆盖点**，让 widget 测试既能断言「确实发起了打开请求」，也能喂入剪贴板
/// HTML 夹具；**未注入时行为与生产完全一致**（与 Flutter 自身的
/// `debugDefaultTargetPlatformOverride` 同一范式）。
library;

/// 覆盖「打开外部网址」的实现；非 null 时 `openExternalUrl` 直接委托给它
/// （协议白名单仍先行判定，故 `javascript:` 一类**不会**进到这里）。
Future<bool> Function(String url)? debugUrlOpenerOverride;

/// 覆盖「读剪贴板 HTML」的实现；非 null 时 `readClipboardHtml` 直接委托给它。
Future<String?> Function()? debugClipboardHtmlOverride;
