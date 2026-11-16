/// 读剪贴板里的**位图**（FR-123 / ADR-047）。
///
/// 为什么需要：Flutter 的剪贴板 API 只承载文本（`ClipboardData.text`），
/// `Clipboard.getData('image/png')` 在嵌入层没有实现；截图工具把截图放进剪贴板的
/// **位图**里，不读它就只能表现为「按了 `Ctrl+V` 没反应」。
///
/// Windows 走自研通道 `sui/platform` 的 `clipboardImage`（`PNG` 注册格式优先，
/// `CF_DIB` 在原生侧补 `BITMAPFILEHEADER` 成 **BMP** 兜底）；其余平台本轮未实现，
/// 恒返回 null。约定：本模块只回**可解码的图片字节**与**魔数判定**，
/// 入库 / 命名 / 落笔在编辑器层（`note_editor.dart` §28.3）。
library;

import 'dart:typed_data';

export 'clipboard_image_web.dart' if (dart.library.io) 'clipboard_image_io.dart';
export 'platform_seams.dart';

/// 按**字节魔数**判定剪贴板图片的扩展名：`png` / `bmp`；不认识返回 null（BR-123.3）。
///
/// **不信任文件名 / MIME**：原生侧只回这两种字节，判不出来说明数据不可用，
/// 调用方应静默放弃（绝不写坏引用，BR-123.2）。
String? clipboardImageExtension(Uint8List bytes) {
  const pngMagic = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (bytes.length >= pngMagic.length) {
    var isPng = true;
    for (var i = 0; i < pngMagic.length; i++) {
      if (bytes[i] != pngMagic[i]) {
        isPng = false;
        break;
      }
    }
    if (isPng) return 'png';
  }
  // BMP：'B' 'M'
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) return 'bmp';
  return null;
}
