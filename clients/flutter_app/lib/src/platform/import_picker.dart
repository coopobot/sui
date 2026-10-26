/// 导入选片的平台条件导入（M13 / FR-60；详细设计
/// `technology/design/low-level-design/file-import.md` §7 / §12）。
///
/// - 原生（桌面 / 移动）：多选文件 + **选择文件夹（递归收集）** + **相对资源解析**（`dart:io`）；
/// - Web：只支持**多选文件**（浏览器沙箱既没有目录路径，也拿不到同级文件）→ 相对资源一律降级。
///
/// 两个实现必须导出**同名同签名**的 [pickImportFiles] / [pickImportFolder] /
/// [importFolderPickSupported]（与 `directory_picker` 同源范式）。
library;

export 'import_picker_web.dart' if (dart.library.io) 'import_picker_io.dart';
