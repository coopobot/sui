#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>

#include <memory>

#include "win32_window.h"

class TrayIcon;

// A window that does nothing but host a Flutter view.
//
// 多窗口（单引擎多视图）：引擎由 multiview_desktop 插件持有，本类只负责创建
// 原生宿主窗口，并把主视图的 Flutter HWND 挂到窗口树里。flutter_controller_
// 已整体移除（插件接管引擎）。
// 详见 technology/adr/012、technology/design/low-level-design/multi-window.md。
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // 托盘「显示主窗口」：还原（若最小化）+ 显示 + 置前。
  void ShowMainWindow();

  // 托盘「退出随手记 Sui」：移除图标并通知 Dart 走 quitApplication；
  // 通道尚不可用时回退为原生退出（M17 / FR-95 / ADR-033）。
  void ExitFromTray();

  // The project to run.
  flutter::DartProject project_;

  // Windows 通知区域图标；创建失败时为 nullptr（关闭行为回退为既有流程）。
  std::unique_ptr<TrayIcon> tray_;

  // 托盘退出兜底时允许 WM_CLOSE 下传，避免再被隐藏逻辑吞掉。
  bool force_close_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
