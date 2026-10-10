/// 目录选择器的平台条件导入（M12 修订 / FR-58）。
///
/// - 原生（桌面 / 移动）：系统目录选择器（`file_picker` 既有依赖）；
/// - Web：无文件系统路径，返回 null（界面也不会渲染入口）。
library;

export 'directory_picker_web.dart' if (dart.library.io) 'directory_picker_io.dart';
