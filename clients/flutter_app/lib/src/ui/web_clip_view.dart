// M16 / FR-83：网页剪藏原件的 WebView 呈现（内嵌 / 全屏）。
//
// 安全边界：
//   * JS 关闭、网络加载关闭、外部导航拦截；
//   * 服务端 HTML 已带 CSP；客户端再兜底一次；
//   * `sui://<sha256>` 图片在加载前替换为 data URI（不依赖自定义 scheme 拦截）。
//
// 测试接缝：`debugWebClipBuilder` 允许 widget 测试注入假 WebView，避免拉起真实平台插件。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 读取原件 HTML 的接缝（sha256 → HTML）。
typedef WebClipHtmlLoader = Future<String?> Function(String sha256);

/// 读取原件内图片字节的接缝（sha256 → bytes）。
typedef WebClipImageResolver = Future<Uint8List?> Function(String sha256);

/// 测试注入的 WebView 构建器；生产为 null（走 [InAppWebView]）。
@visibleForTesting
Widget Function(BuildContext context, String html, double height)? debugWebClipBuilder;

/// 是否由本平台提供 WebView。Linux / 未知平台返回 false（调用方降级）。
bool webClipWebViewSupported() {
  if (kIsWeb) return true;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return true;
    default:
      return false;
  }
}

/// 网页原件单元（内嵌预览）。
class WebClipView extends StatefulWidget {
  const WebClipView({
    super.key,
    required this.html,
    required this.height,
    this.title,
    this.imageResolver,
    this.onOpenExternal,
    this.fallback,
  });

  final String html;
  final double height;
  final String? title;
  final WebClipImageResolver? imageResolver;

  /// 「在浏览器打开」入口；null 时不显示。
  final VoidCallback? onOpenExternal;

  /// WebView 不可用 / 加载失败时的降级组件。
  final Widget? fallback;

  @override
  State<WebClipView> createState() => _WebClipViewState();
}

class _WebClipViewState extends State<WebClipView> {
  String? _prepared;
  Object? _error;
  WebViewEnvironment? _environment;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _environment?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant WebClipView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _prepared = null;
      _error = null;
      _prepare();
    }
  }

  Future<void> _prepare() async {
    try {
      // Windows 未安装 WebView2 Runtime 时，构建 InAppWebView 可能直接失败；
      // 先做一次运行时探测，失败走降级卡片（FR-83 / BR-83.4）。
      if (!await _webViewRuntimeAvailable()) {
        if (!mounted) return;
        setState(() => _error = 'WebView2 Runtime unavailable');
        return;
      }
      if (kIsWeb) {
        // Web 没有自定义 scheme 拦截，只能内联 data URI；给总预算，避免几十 MB 的
        // base64 把页面卡死（图片超预算时用透明像素占位，正文与布局仍先出来）。
        final prepared = await resolveWebClipImages(
          widget.html,
          widget.imageResolver,
          maxTotalBytes: 8 << 20,
          maxImageBytes: 2 << 20,
        );
        if (!mounted) return;
        setState(() => _prepared = prepared);
        return;
      }

      // 桌面 / 移动：保留 `sui://<sha256>`，由 WebView 的自定义 scheme 按需取图
      // （见 _InAppWebViewBody）。这样 HTML 只有原件本身的体积，不再把 27 MB
      // 图片 base64 成 37 MB 字符串后一次性塞给 WebView。
      var prepared = _enableSuiImages(widget.html);
      if (defaultTargetPlatform == TargetPlatform.windows) {
        try {
          _environment = await WebViewEnvironment.create(
            settings: WebViewEnvironmentSettings(
              customSchemeRegistrations: [
                CustomSchemeRegistration(
                  scheme: 'sui',
                  hasAuthorityComponent: true,
                  treatAsSecure: true,
                ),
              ],
            ),
          );
        } catch (_) {
          // 旧版 WebView2 Runtime 不支持自定义 scheme 注册：退回 data URI 预算路径，
          // 至少让页面正文先出来，而不是整块降级为「原件不可用」。
          prepared = await resolveWebClipImages(
            widget.html,
            widget.imageResolver,
            maxTotalBytes: 8 << 20,
            maxImageBytes: 2 << 20,
          );
        }
      }
      if (!mounted) return;
      setState(() => _prepared = prepared);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  Future<bool> _webViewRuntimeAvailable() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return true;
    try {
      final version = await WebViewEnvironment.getAvailableVersion();
      return version != null && version.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = widget.fallback ??
        WebClipFallback(
          title: widget.title,
          onOpenExternal: widget.onOpenExternal,
        );
    if (!webClipWebViewSupported() || _error != null) {
      return SizedBox(height: widget.height, child: fallback);
    }
    if (_prepared == null) {
      return SizedBox(
        height: widget.height,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final debug = debugWebClipBuilder;
    if (debug != null) {
      return SizedBox(
        height: widget.height,
        child: debug(context, _prepared!, widget.height),
      );
    }
    return SizedBox(
      height: widget.height,
      child: _InAppWebViewBody(
        html: _prepared!,
        imageResolver: widget.imageResolver,
        environment: _environment,
        onError: (_) {
          if (mounted) setState(() => _error = 'load failed');
        },
      ),
    );
  }
}

/// 把 HTML 里的 `sui://<sha256>` 图片替换为 `data:` URI（Web 降级路径）。
///
/// [maxTotalBytes] / [maxImageBytes] 是**原始图片字节**预算：超预算的图片用透明像素
/// 占位。没有预算时，79 张图 / 27 MB 原图会被 base64 成 37 MB HTML，WebView 直接卡死。
Future<String> resolveWebClipImages(
  String html,
  WebClipImageResolver? resolver, {
  int maxTotalBytes = 8 << 20,
  int maxImageBytes = 2 << 20,
}) async {
  if (resolver == null || !html.contains('sui://')) return html;
  final re = RegExp(r'sui://([0-9a-fA-F]{64})');
  final matches = re.allMatches(html).toList();
  if (matches.isEmpty) return html;
  final cache = <String, String>{};
  var out = html;
  var used = 0;
  for (final m in matches) {
    final sha = m.group(1)!;
    if (!cache.containsKey(sha)) {
      final bytes = await resolver(sha);
      if (bytes == null ||
          bytes.length > maxImageBytes ||
          used + bytes.length > maxTotalBytes) {
        cache[sha] = _transparentPixel;
      } else {
        used += bytes.length;
        cache[sha] = 'data:${_mimeOf(bytes)};base64,${base64Encode(bytes)}';
      }
    }
    out = out.replaceAll(m.group(0)!, cache[sha]!);
  }
  return out;
}

/// 旧原件（服务端 CSP 只写了 `img-src data:`）补上 `sui:`，否则自定义 scheme 图片被 CSP 拦掉。
String _enableSuiImages(String html) =>
    html.replaceAll('img-src data:', 'img-src data: sui:');

const String _transparentPixel =
    'data:image/gif;base64,R0lGODlhAQABAAAAACw=';

String _mimeOf(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 6 &&
      b[0] == 0x47 &&
      b[1] == 0x49 &&
      b[2] == 0x46) {
    return 'image/gif';
  }
  if (b.length >= 12 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  if (b.length >= 4 && b[0] == 0x3C && b[1] == 0x73 && b[2] == 0x76) {
    return 'image/svg+xml';
  }
  return 'image/png';
}

class _InAppWebViewBody extends StatelessWidget {
  const _InAppWebViewBody({
    required this.html,
    required this.onError,
    this.imageResolver,
    this.environment,
  });

  final String html;
  final void Function(Object error) onError;
  final WebClipImageResolver? imageResolver;
  final WebViewEnvironment? environment;

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      webViewEnvironment: environment,
      initialData: InAppWebViewInitialData(
        data: html,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri('about:blank'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: false,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        // 不用 blockNetworkLoads：WebView2 可能把它套到自定义 scheme 请求上，
        // 导致 `sui://` 图片也加载不出来；网络仍由原件 CSP（default-src 'none'）
        // 与「JS 关闭 + 外部导航拦截」共同禁止。
        blockNetworkLoads: false,
        useShouldOverrideUrlLoading: true,
        disableContextMenu: true,
        allowsInlineMediaPlayback: false,
        mediaPlaybackRequiresUserGesture: true,
        transparentBackground: true,
        // Android / iOS / macOS 用该列表注册自定义 scheme；Windows 走
        // WebViewEnvironment.customSchemeRegistrations（见 _prepare）。
        resourceCustomSchemes: const ['sui'],
      ),
      onLoadResourceWithCustomScheme: (controller, request) async {
        final uri = request.url;
        if (uri.scheme.toLowerCase() != 'sui') return null;
        final sha = uri.host.isNotEmpty
            ? uri.host
            : (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '');
        final bytes = await imageResolver?.call(sha);
        if (bytes == null || bytes.isEmpty) return null;
        return CustomSchemeResponse(
          contentType: _mimeOf(bytes),
          data: bytes,
        );
      },
      shouldOverrideUrlLoading: (controller, action) async {
        final uri = action.request.url;
        if (uri == null) return NavigationActionPolicy.ALLOW;
        final scheme = uri.scheme.toLowerCase();
        if (scheme == 'about' || scheme == 'data') {
          return NavigationActionPolicy.ALLOW;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame ?? false) onError(error);
      },
    );
  }
}

/// 降级卡片：WebView 不可用 / 原件缺失。
class WebClipFallback extends StatelessWidget {
  const WebClipFallback({super.key, this.title, this.onOpenExternal});

  final String? title;
  final VoidCallback? onOpenExternal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.public_off, color: scheme.outline, size: 32),
          const SizedBox(height: 8),
          Text(
            title == null || title!.isEmpty ? '网页原件不可用' : title!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '当前平台不支持内嵌预览，或原件尚未同步到本机',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.outline),
          ),
          if (onOpenExternal != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onOpenExternal,
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('打开原件'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 全屏网页原件查看页。
class WebClipViewerPage extends StatelessWidget {
  const WebClipViewerPage({
    super.key,
    required this.title,
    required this.html,
    this.imageResolver,
  });

  final String title;
  final String html;
  final WebClipImageResolver? imageResolver;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title.isEmpty ? '网页原件' : title)),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => WebClipView(
            html: html,
            height: constraints.maxHeight,
            title: title,
            imageResolver: imageResolver,
          ),
        ),
      ),
    );
  }
}

/// 打开全屏网页原件。
Future<void> showWebClipViewer(
  BuildContext context, {
  required String title,
  required String html,
  WebClipImageResolver? imageResolver,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => WebClipViewerPage(
        title: title,
        html: html,
        imageResolver: imageResolver,
      ),
    ),
  );
}

/// 从 blob 字节解码 HTML（容错 UTF-8）。
String? decodeWebClipHtml(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  return utf8.decode(bytes, allowMalformed: true);
}
