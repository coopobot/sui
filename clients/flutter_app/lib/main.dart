import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/bootstrap.dart';
import 'src/platform/multi_window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await bootstrapStorage();
  // 桌面端多窗口（M8 · FR-42/FR-43 · ADR-012）：以 runMultiApp 取代 runApp；
  // 其余平台沿用单视图入口（详细设计 §3.4 / §6）。分流经条件导入，Web 构建安全。
  if (supportsMultiWindow) {
    runMultiWindowApp(storage: storage);
  } else {
    runApp(SuiApp(storage: storage));
  }
}
