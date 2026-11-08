/// 外部打开附件的结果（FR-47 / FR-110 / ADR-040）。
///
/// **为什么不是布尔**：用户看到的那句话必须能指导下一步动作——
/// 「本机没有可打开该附件的应用」应当建议改用内置预览；
/// 「当前平台不支持」则连这个建议都不该给（Web / iOS 上预览才是唯一路径）。
/// 布尔值无法区分这两件事，会把「设备缺应用」伪装成「平台没实现」，
/// 正是 FR-110 要消灭的那类误导。
library;

/// 外部打开的四态结果。
enum ExternalOpenOutcome {
  /// 已交给系统（桌面壳层唤起 / Android `ACTION_VIEW`）。
  opened,

  /// 平台支持，但**本机没有能处理该类型的应用**（Android `ActivityNotFoundException`）。
  noHandler,

  /// 平台本身不支持（Web / iOS）。
  unsupported,

  /// 平台支持且已尝试，但落盘 / 唤起过程出错。
  failed,
}

/// [ExternalOpenOutcome] 的载体，同时带回临时文件路径与「是否值得监视回写」。
class ExternalOpenResult {
  const ExternalOpenResult(
    this.outcome, {
    this.path,
    this.watchForEdits = false,
  });

  /// 平台不支持的快捷构造。
  const ExternalOpenResult.unsupported()
      : outcome = ExternalOpenOutcome.unsupported,
        path = null,
        watchForEdits = false;

  final ExternalOpenOutcome outcome;

  /// 临时文件绝对路径（外部编辑回写时据此重读，BR-47.3）；未打开成功时为 null。
  final String? path;

  /// 是否启动**外部编辑回写监视**（AC-150）。
  ///
  /// 只有桌面三平台为 true：Android 走只读授权（`FLAG_GRANT_READ_URI_PERMISSION`），
  /// 第三方应用无法写回该临时文件，监视只会空转（ADR-040 决策 2 / BR-110.6）。
  final bool watchForEdits;

  bool get isOpened => outcome == ExternalOpenOutcome.opened;
}
