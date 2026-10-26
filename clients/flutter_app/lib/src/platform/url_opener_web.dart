import 'dart:js_interop';

import 'platform_seams.dart';
import 'url_schemes.dart';

/// `window` 的最小 JS 互操作绑定（只用 `open`；`dart:js_interop` 是 SDK 自带库，
/// 不引入任何 pub 依赖，满足 BR-70.3）。
@JS('window')
external _Window get _window;

extension type _Window(JSObject _) implements JSObject {
  external JSAny? open(String url, String target);
}

/// Web 端用浏览器新标签页打开 [url]（FR-70 / ADR-028）。
Future<bool> openExternalUrl(String url) async {
  final target = url.trim();
  if (!isOpenableUrl(target)) return false;
  final override = debugUrlOpenerOverride;
  if (override != null) return override(target);
  try {
    _window.open(target, '_blank');
    return true;
  } catch (_) {
    return false;
  }
}
