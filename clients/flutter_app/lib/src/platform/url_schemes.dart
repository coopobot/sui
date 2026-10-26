/// 可打开网址的**协议白名单**（FR-70 / BR-70.2，见 ADR-028）。
///
/// 只放行 `http` / `https`（交系统默认浏览器）与 `mailto` / `tel`（交系统壳层）；
/// `javascript:` / `data:` / `file:` / `vbscript:` 等一律**拒绝**——它们既可能触发本机
/// 文件访问或脚本执行，也会在预览里呈现为「看着像链接、点开却有副作用」的东西。
library;

/// 协议白名单（小写、不含 `:`）。
const Set<String> kOpenableUrlSchemes = <String>{
  'http',
  'https',
  'mailto',
  'tel',
};

/// [url] 是否属于可打开白名单（协议合法 + `http(s)` 必须有主机名）。
///
/// 纯函数，供 UI 层在渲染链接条 / 预览链接时判定「能不能点」，也供单测直接覆盖。
bool isOpenableUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  if (!kOpenableUrlSchemes.contains(scheme)) return false;
  if ((scheme == 'http' || scheme == 'https') && uri.host.isEmpty) return false;
  return true;
}
