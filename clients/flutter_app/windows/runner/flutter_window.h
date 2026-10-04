#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>

#include <memory>

#include "win32_window.h"

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
  // The project to run.
  flutter::DartProject project_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
