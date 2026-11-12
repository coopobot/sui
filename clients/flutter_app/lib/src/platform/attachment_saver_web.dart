import 'dart:js_interop';
import 'dart:typed_data';

import 'attachment_save.dart';
import 'platform_seams.dart';

/// Web 端「保存到本地」= **浏览器下载**（FR-117 / BR-117.3 / ADR-042 决策 2）。
///
/// 用 SDK 自带的 `dart:js_interop` 完成 `Blob` + `a[download]`，不引入
/// `package:web` / `dart:html`（与 `url_opener_web.dart` 同一零依赖口径）：
/// 1. `Uint8List.toJS` → `Uint8Array`；
/// 2. `new Blob([bytes])`；
/// 3. `URL.createObjectURL` → 临时 `<a download>` → `click()` → 移除 → `revokeObjectURL`。
///
/// 不打开新标签页、不改路由；浏览器接管落盘（受浏览器下载设置约束）。
Future<AttachmentSaveResult> saveAttachmentToDevice({
  required String filename,
  required Uint8List bytes,
}) async {
  final override = debugAttachmentSaveOverride;
  if (override != null) return override(filename: filename, bytes: bytes);

  final name = sanitizeAttachmentFilename(filename);
  String? objectUrl;
  try {
    final blob = _Blob(<JSAny>[bytes.toJS].toJS);
    objectUrl = _Url.createObjectURL(blob);
    final anchor = _document.createElement('a');
    anchor.href = objectUrl;
    anchor.download = name;
    // Firefox 要求节点在文档里才会响应 click()。
    _document.body.appendChild(anchor);
    anchor.click();
    _document.body.removeChild(anchor);
    return const AttachmentSaveResult(AttachmentSaveOutcome.startedDownload);
  } catch (_) {
    return const AttachmentSaveResult(AttachmentSaveOutcome.failed);
  } finally {
    if (objectUrl != null) {
      try {
        _Url.revokeObjectURL(objectUrl);
      } catch (_) {}
    }
  }
}

@JS('document')
external _Document get _document;

extension type _Document(JSObject _) implements JSObject {
  external _Body get body;
  external _Anchor createElement(String tagName);
}

extension type _Body(JSObject _) implements JSObject {
  external void appendChild(_Anchor node);
  external void removeChild(_Anchor node);
}

extension type _Anchor(JSObject _) implements JSObject {
  external set href(String value);
  external set download(String value);
  external void click();
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts);
}

@JS('URL')
extension type _Url._(JSObject _) implements JSObject {
  external static String createObjectURL(_Blob blob);
  external static void revokeObjectURL(String url);
}
