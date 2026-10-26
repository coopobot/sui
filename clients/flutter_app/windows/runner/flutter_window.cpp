#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "sui_platform_channel.h"
#include <multiview_desktop/multi_view_desktop_plugin.h>

namespace {

// 插件注册回调：先跑生成文件里的插件（multiview_desktop / sqlite3_flutter_libs），
// 再补注册自研平台通道 `sui/platform`（FR-70 打开链接 / FR-71 剪贴板富文本，见 ADR-028）。
//
// 生成文件 `generated_plugin_registrant.cc` 是 `flutter pub get` 的产物、不许手改，
// 故自研通道挂在 runner 这一层，由本回调转交注册。
void RegisterAppPlugins(flutter::PluginRegistry* registry) {
  RegisterPlugins(registry);
  SuiPlatformChannelRegister(registry->GetRegistrarForPlugin("SuiPlatform"));
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();
  const int width = frame.right - frame.left;
  const int height = frame.bottom - frame.top;

  // 引擎由插件持有：先准备引擎，再创建主视图，最后把主视图的 Flutter HWND
  // 挂进窗口树。RegisterPlugins 在主视图存在后回调，供需要 GetView() 的
  // 插件（托盘等）注册。
  MultiViewDesktopPrepareEngine(project_, GetHandle());
  MultiViewDesktopCreateMainView(GetHandle(), width, height, RegisterAppPlugins);
  const HWND flutter_hwnd =
      MultiViewDesktopGetFlutterHwnd(MultiViewDesktopGetMainViewId());
  if (flutter_hwnd != nullptr) {
    SetChildContent(flutter_hwnd);
  }
  CenterOnScreen();

  return true;
}

void FlutterWindow::OnDestroy() {
  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  LRESULT result = 0;
  if (message == WM_FONTCHANGE) {
    FlutterDesktopEngineReloadSystemFonts(MultiViewDesktopGetEngineRef());
  }
  if (MultiViewDesktopHandleWindowProc(hwnd, message, wparam, lparam, &result)) {
    return result;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
