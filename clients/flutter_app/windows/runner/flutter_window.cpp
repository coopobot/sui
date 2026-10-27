#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "sui_platform_channel.h"
#include "tray_icon.h"
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

  // M17 / FR-95：主窗口创建后注册系统托盘图标。失败时 tray_ 为空，
  // WM_CLOSE 会按既有流程下传，窗口不会被隐藏到无法恢复的状态。
  tray_ = std::make_unique<TrayIcon>(
      GetHandle(), [this]() { ShowMainWindow(); },
      [this]() { ExitFromTray(); });
  if (!tray_->Add()) {
    tray_.reset();
  }

  return true;
}

void FlutterWindow::OnDestroy() {
  if (tray_) {
    tray_->Remove();
    tray_.reset();
  }
  Win32Window::OnDestroy();
}

void FlutterWindow::ShowMainWindow() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) return;
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  } else {
    ShowWindow(hwnd, SW_SHOW);
  }
  SetForegroundWindow(hwnd);
}

void FlutterWindow::ExitFromTray() {
  force_close_ = true;
  if (tray_) {
    tray_->Remove();
    tray_.reset();
  }

  // 优先回到 Dart 的 quitApplication()：flush 编辑器 + 尽力同步后再退出。
  if (SuiPlatformRequestTrayExit()) {
    return;
  }

  // 引擎尚未注册通道（极端启动窗口期）：native 兜底退出，保证菜单有响应。
  if (HWND hwnd = GetHandle()) {
    DestroyWindow(hwnd);
  }
  PostQuitMessage(0);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // M17 / FR-95：托盘存在时，主窗口关闭 = 隐藏到托盘（不销毁窗口 / 引擎 / 进程）。
  // 必须先于 multiview_desktop 的 WM_CLOSE 处理，否则会进入 softCascade 销毁窗口。
  if (message == WM_CLOSE && !force_close_ && tray_ != nullptr &&
      tray_->visible()) {
    ShowWindow(hwnd, SW_HIDE);
    return 0;
  }

  LRESULT result = 0;
  if (tray_ != nullptr &&
      tray_->HandleMessage(hwnd, message, wparam, lparam, &result)) {
    return result;
  }

  if (message == WM_FONTCHANGE) {
    FlutterDesktopEngineReloadSystemFonts(MultiViewDesktopGetEngineRef());
  }
  if (MultiViewDesktopHandleWindowProc(hwnd, message, wparam, lparam, &result)) {
    return result;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
