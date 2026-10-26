#include <flutter/dart_project.h>
#include <windows.h>

#include <multiview_desktop/multi_view_desktop_plugin.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 多窗口：初始化 shell 集成（任务栏跳转列表），并在此进程创建 Flutter 窗口
  // 之前，把由跳转列表触发的 --mvd-taskbar-menu=<id> 激活转发给已在运行的实例。
  MultiViewDesktopInitializeShellIntegration();

  if (MultiViewDesktopTryForwardTaskbarMenuActivation()) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"随手记 Sui", origin, size)) {
    return EXIT_FAILURE;
  }
  // 多窗口：关闭主窗口不退出进程，进程生命周期交由 multiview_desktop 的
  // CloseMode 控制（关闭最后一个窗口才退出）。
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
