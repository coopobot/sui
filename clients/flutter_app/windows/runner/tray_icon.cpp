#include "tray_icon.h"

#include <shellapi.h>

#include <utility>

#include "resource.h"

namespace {

constexpr wchar_t kTooltip[] = L"随手记 Sui";
constexpr UINT kIconId = 1;

// 填充 NIM_ADD / NIM_DELETE 共用的窗口句柄、图标 id 与 tooltip。
void FillIconData(NOTIFYICONDATAW* data, HWND owner, UINT callback_message) {
  data->cbSize = sizeof(NOTIFYICONDATAW);
  data->hWnd = owner;
  data->uID = kIconId;
  data->uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data->uCallbackMessage = callback_message;
  data->hIcon = nullptr;
  lstrcpynW(data->szTip, kTooltip, static_cast<int>(ARRAYSIZE(data->szTip)));
}

}  // namespace

TrayIcon::TrayIcon(HWND owner, Callback show_window, Callback exit_app)
    : owner_(owner),
      show_window_(std::move(show_window)),
      exit_app_(std::move(exit_app)),
      // 与应用窗口 / 安装包同源（Runner.rc 的 IDI_APP_ICON）。
      icon_(LoadIconW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON))),
      taskbar_created_message_(RegisterWindowMessageW(L"TaskbarCreated")) {}

TrayIcon::~TrayIcon() { Remove(); }

bool TrayIcon::Add() {
  if (added_) return true;
  if (owner_ == nullptr) return false;

  NOTIFYICONDATAW data{};
  FillIconData(&data, owner_, kCallbackMessage);
  data.hIcon =
      icon_ != nullptr ? icon_ : LoadIconW(nullptr, IDI_APPLICATION);

  if (!Shell_NotifyIconW(NIM_ADD, &data)) {
    return false;
  }
  added_ = true;
  return true;
}

void TrayIcon::Remove() {
  if (!added_ || owner_ == nullptr) return;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(NOTIFYICONDATAW);
  data.hWnd = owner_;
  data.uID = kIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  added_ = false;
}

bool TrayIcon::HandleMessage(HWND hwnd,
                             UINT message,
                             WPARAM wparam,
                             LPARAM lparam,
                             LRESULT* result) {
  // Explorer 重启后会广播 TaskbarCreated；此时旧图标已消失，需要重新注册。
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    added_ = false;
    Add();
    if (result != nullptr) *result = 0;
    return true;
  }

  if (message != kCallbackMessage) return false;

  const UINT event = static_cast<UINT>(lparam);
  switch (event) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      if (show_window_) show_window_();
      break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowContextMenu();
      break;
    default:
      break;
  }

  if (result != nullptr) *result = 0;
  return true;
}

void TrayIcon::ShowContextMenu() {
  if (owner_ == nullptr) return;

  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;

  AppendMenuW(menu, MF_STRING, kMenuShowWindow, L"显示主窗口");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuExit, L"退出随手记 Sui");

  POINT cursor{};
  GetCursorPos(&cursor);

  // 托盘菜单需要 owner 在前台，否则点击菜单外部不会自动关闭。
  SetForegroundWindow(owner_);
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, owner_,
      nullptr);
  DestroyMenu(menu);
  PostMessageW(owner_, WM_NULL, 0, 0);

  if (command == kMenuShowWindow) {
    if (show_window_) show_window_();
  } else if (command == kMenuExit) {
    if (exit_app_) exit_app_();
  }
}
