#ifndef RUNNER_SUI_PLATFORM_CHANNEL_H_
#define RUNNER_SUI_PLATFORM_CHANNEL_H_

#include <flutter_windows.h>

#include <flutter/plugin_registrar_windows.h>

// 注册「随手记 Sui」自研平台通道 `sui/platform`（FR-70 / FR-71 / ADR-028）。
//
// 为什么自建而不引第三方插件：
// * 剪贴板的 **HTML 表示**（Windows 的 `HTML Format` 即 CF_HTML）在 Flutter 嵌入层
//   没有实现——内建 `Clipboard.getData` 只支持 `text/plain`，其它格式一律报错，
//   于是「粘贴保留原格式」此前一直静默失效；
// * 读一个剪贴板格式只需十几行 Win32 代码，不值得为此引入原生插件依赖
//   （Agents.md §6 第 4 条：依赖增删须先经批准）。
//
// 口径：通道**只回原始字节**（CF_HTML 的完整字节流），头部解析与 HTML→Markdown
// 转换全在 Dart 侧完成（`lib/src/platform/cf_html.dart` + note_core 的 DOM 转换器），
// 便于单测与跨平台复用。
// 参数类型是 **C 句柄**（不是 `flutter::PluginRegistrarWindows*`）：本工程的引擎由
// `multiview_desktop` 插件持有，它的 `PluginRegistry::GetRegistrarForPlugin` 返回 C 句柄
// （生成文件里的 `*PluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef)` 即此形态）。
// 实现侧经 `flutter::PluginRegistrarManager` 取对应的 C++ registrar 再拿 messenger。
void SuiPlatformChannelRegister(FlutterDesktopPluginRegistrarRef registrar);

#endif  // RUNNER_SUI_PLATFORM_CHANNEL_H_
