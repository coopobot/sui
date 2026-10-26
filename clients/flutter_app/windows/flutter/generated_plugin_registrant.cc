//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <flutter_inappwebview_windows/flutter_inappwebview_windows_plugin_c_api.h>
#include <multiview_desktop/multi_view_desktop_plugin.h>
#include <sqlite3_flutter_libs/sqlite3_flutter_libs_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterInappwebviewWindowsPluginCApi"));
  MultiViewDesktopPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MultiViewDesktopPlugin"));
  Sqlite3FlutterLibsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("Sqlite3FlutterLibsPlugin"));
}
