/// 本地存储位置解析与迁移的平台条件导入（M12 修订 / FR-58）。
///
/// - 原生（桌面 / 移动）：`storage_location_io.dart` —— 桌面端启用该能力，
///   移动端界面不渲染入口（BR-58.8）；
/// - Web：`storage_location_web.dart` —— 无文件系统路径，能力不支持。
///
/// **常量**（文件名 / 校验表）由 `storage_location_constants.dart` **无条件导出**：
/// 条件导入在不同分析目标下的解析差异，不应影响调用方能否看到这些名字。
///
/// 详细设计见 `technology/design/low-level-design/local-storage.md`，决策见 ADR-022。
library;

export 'storage_location_constants.dart';
export 'storage_location_web.dart' if (dart.library.io) 'storage_location_io.dart';
