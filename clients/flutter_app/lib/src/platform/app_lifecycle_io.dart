import 'dart:io';

/// 原生平台：结束进程。
///
/// 退出前的「编辑器防抖落库 + 尽力推送」已由 `AppController.quitApplication()`
/// 完成，此处只做最后的进程终止（详细设计 §7）。
void exitApp() => exit(0);
