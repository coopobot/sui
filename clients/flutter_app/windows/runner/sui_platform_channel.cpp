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
  result->NotImplemented();
}

}  // namespace

void SuiPlatformChannelRegister(FlutterDesktopPluginRegistrarRef registrar_ref) {
  // 通道生命周期与引擎绑定：注册后**不能**析构，故有意长期持有。
  static flutter::MethodChannel<flutter::EncodableValue>* channel = nullptr;
  if (channel != nullptr) {
    return;
  }
  // 本工程的引擎由 `multiview_desktop` 插件持有，注册回调给的是 **C 句柄**；经
  // `PluginRegistrarManager` 取（并长期持有）对应的 C++ registrar，再拿 messenger。
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            registrar_ref);
  channel = new flutter::MethodChannel<flutter::EncodableValue>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) { HandleMethodCall(call, std::move(result)); });
}
