#include "sui_platform_channel.h"

#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "sui/platform";

// 通道生命周期与引擎绑定：注册后**不能**析构，故有意长期持有。
// 托盘退出需要由 native 反向调用 Dart（M17 / FR-95），因此提升为文件级指针。
flutter::MethodChannel<flutter::EncodableValue>* g_channel = nullptr;

// 读剪贴板的 CF_HTML（"HTML Format"）**原始字节**。
//
// HGLOBAL 的内容是字节流：ASCII 头部（含 StartFragment / EndFragment 的**字节**偏移）
// + UTF-8 的 HTML 正文，故原样取字节（连同尾部可能的 NUL），切片交给 Dart。
std::optional<std::vector<uint8_t>> ReadClipboardHtml() {
  static UINT cf_html = RegisterClipboardFormatW(L"HTML Format");
  if (cf_html == 0 || !IsClipboardFormatAvailable(cf_html)) {
    return std::nullopt;
  }
  if (!OpenClipboard(nullptr)) {
    return std::nullopt;
  }
  std::optional<std::vector<uint8_t>> out;
  if (HANDLE handle = GetClipboardData(cf_html); handle != nullptr) {
    if (const auto* data = static_cast<const uint8_t*>(GlobalLock(handle));
        data != nullptr) {
      const SIZE_T size = GlobalSize(handle);
      if (size > 0) {
        out = std::vector<uint8_t>(data, data + size);
      }
      GlobalUnlock(handle);
    }
  }
  CloseClipboard();
  return out;
}

// 读剪贴板里的**位图**（截图工具复制到剪贴板的常见形态），返回可直接解码的图片字节。
//
// 为什么需要：Flutter 的 `ClipboardData` 只承载文本（`text/plain` / `text/html`），
// 嵌入层没有 `image/*` 实现；截图工具通常只写位图格式，于是粘贴链路拿不到任何来源
// （用户表现：按 Ctrl+V 没反应，见 FR-123 / ADR-047）。
//
// 返回口径：
// * 剪贴板有注册格式 `PNG`（Win11 截图工具 / Snipaste / 浏览器等常见）→ 原样 PNG 字节；
// * 否则读 `CF_DIB`（DIB 没有文件头）→ 补一个 `BITMAPFILEHEADER` 成 **BMP** 字节
//   （不做 WIC / COM 转码：BMP 能被 Skia 全端解码，而 COM 初始化在通道回调线程上有风险）；
// * 都没有 → null（Dart 侧静默回落，绝不报错）。
std::optional<std::vector<uint8_t>> ReadClipboardImage() {
  static UINT cf_png = RegisterClipboardFormatW(L"PNG");
  const bool has_png = cf_png != 0 && IsClipboardFormatAvailable(cf_png);
  const bool has_dib = IsClipboardFormatAvailable(CF_DIB) != FALSE;
  if (!has_png && !has_dib) {
    return std::nullopt;
  }
  if (!OpenClipboard(nullptr)) {
    return std::nullopt;
  }

  auto read_format = [](UINT format) -> std::optional<std::vector<uint8_t>> {
    HANDLE handle = GetClipboardData(format);
    if (handle == nullptr) {
      return std::nullopt;
    }
    const auto* data = static_cast<const uint8_t*>(GlobalLock(handle));
    if (data == nullptr) {
      return std::nullopt;
    }
    std::optional<std::vector<uint8_t>> out;
    const SIZE_T size = GlobalSize(handle);
    if (size > 0) {
      out = std::vector<uint8_t>(data, data + size);
    }
    GlobalUnlock(handle);
    return out;
  };

  std::optional<std::vector<uint8_t>> out;
  if (has_png) {
    out = read_format(cf_png);
  }
  if (!out.has_value() && has_dib) {
    auto dib = read_format(CF_DIB);
    // DIB 至少含一个 BITMAPINFOHEADER；header 长度由 biSize 给出（可能是 V4 / V5）。
    if (dib.has_value() && dib->size() > sizeof(BITMAPINFOHEADER)) {
      const auto* bih = reinterpret_cast<const BITMAPINFOHEADER*>(dib->data());
      const bool header_ok =
          bih->biSize >= sizeof(BITMAPINFOHEADER) && bih->biSize <= dib->size();
      if (header_ok) {
        std::size_t palette = 0;
        if (bih->biBitCount <= 8) {
          const std::size_t colors = bih->biClrUsed != 0
                                         ? bih->biClrUsed
                                         : (std::size_t{1} << bih->biBitCount);
          palette = colors * sizeof(RGBQUAD);
        }
        if (bih->biSize + palette <= dib->size()) {
          BITMAPFILEHEADER file_header{};
          file_header.bfType = 0x4D42;  // 'B' 'M'
          file_header.bfOffBits = static_cast<DWORD>(
              sizeof(BITMAPFILEHEADER) + bih->biSize + palette);
          file_header.bfSize = static_cast<DWORD>(
              sizeof(BITMAPFILEHEADER) + dib->size());
          std::vector<uint8_t> bmp;
          bmp.reserve(sizeof(BITMAPFILEHEADER) + dib->size());
          bmp.insert(
              bmp.end(),
              reinterpret_cast<const uint8_t*>(&file_header),
              reinterpret_cast<const uint8_t*>(&file_header) +
                  sizeof(file_header));
          bmp.insert(bmp.end(), dib->begin(), dib->end());
          out = std::move(bmp);
        }
      }
    }
  }
  CloseClipboard();
  return out;
}

void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "clipboardHtml") {
    const auto html = ReadClipboardHtml();
    if (!html.has_value()) {
      // null：Dart 侧据此回落纯文本（不是错误，剪贴板里就是没有 HTML 表示）。
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(flutter::EncodableValue(html.value()));
    return;
  }
  if (call.method_name() == "clipboardImage") {
    const auto image = ReadClipboardImage();
    if (!image.has_value()) {
      // null：Dart 侧据此回落文本（不是错误，剪贴板里就是没有位图）。
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(flutter::EncodableValue(image.value()));
    return;
  }
  result->NotImplemented();
}

}  // namespace

void SuiPlatformChannelRegister(FlutterDesktopPluginRegistrarRef registrar_ref) {
  if (g_channel != nullptr) {
    return;
  }
  // 本工程的引擎由 `multiview_desktop` 插件持有，注册回调给的是 **C 句柄**；经
  // `PluginRegistrarManager` 取（并长期持有）对应的 C++ registrar，再拿 messenger。
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            registrar_ref);
  g_channel = new flutter::MethodChannel<flutter::EncodableValue>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) { HandleMethodCall(call, std::move(result)); });
}

bool SuiPlatformRequestTrayExit() {
  if (g_channel == nullptr) return false;
  g_channel->InvokeMethod("trayExitRequested", nullptr);
  return true;
}
