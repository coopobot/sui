#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>

// Windows 通知区域（系统托盘）图标（M17 / FR-95 / ADR-033）。
//
// 只依赖 Win32 Shell API，不引入第三方 Flutter 插件。图标注册在主窗口句柄上：
// 主窗口隐藏后句柄仍然有效，托盘消息与右键菜单因此继续可用。
class TrayIcon {
 public:
  using Callback = std::function<void()>;

  TrayIcon(HWND owner, Callback show_window, Callback exit_app);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // 注册图标；失败返回 false（调用方据此回退到「关闭即关闭」）。
  bool Add();

  // 移除图标；可重复调用。
  void Remove();

  // 返回 true 表示消息已被托盘消费（调用方不再向下传递）。
  bool HandleMessage(HWND hwnd,
                     UINT message,
                     WPARAM wparam,
                     LPARAM lparam,
                     LRESULT* result);

  bool visible() const { return added_; }

 private:
  void ShowContextMenu();

  static constexpr UINT kCallbackMessage = WM_APP + 101;
  static constexpr UINT kMenuShowWindow = 1;
  static constexpr UINT kMenuExit = 2;

  HWND owner_ = nullptr;
  Callback show_window_;
  Callback exit_app_;
  HICON icon_ = nullptr;
  UINT taskbar_created_message_ = 0;
  bool added_ = false;
};

#endif  // RUNNER_TRAY_ICON_H_
