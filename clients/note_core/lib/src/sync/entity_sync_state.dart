/// 逐项同步状态（M12 / FR-53）。
///
/// **纯本地记账**：该状态描述「本端这一条实体相对云端的关系」，因此
/// **不写入 Markdown 正本、不进入 push/pull 净荷、服务端不存储**（BR-53.3）。
/// 判定口径与状态机见 `technology/design/low-level-design/sync-status.md` §2。
library;

/// 单条实体（笔记本 / 笔记 / 标签）与云端的一致状态。
enum EntitySyncState {
  /// 本端无未确认改动，且已知服务端版本与本端基线一致。
  synced(0),

  /// 本端有未上行的改动，且云端**已知持有**该实体。
  pending(1),

  /// 云端**从未持有**该实体（核对确认不存在）。
  localOnly(2),

  /// 云端持有、版本 ≠ 本端基线，**且**本端仍有未上行改动
  /// （含加密笔记本未解锁、无法就地合并的情形）。
  conflict(3),

  /// 最近一次针对该项的上行 / 下行失败（原因见 `syncError`）。
  failed(4);

  const EntitySyncState(this.code);

  /// 落库值（`sync_state` 列）。
  final int code;

  /// 由落库值还原；未知值按**保守态** `pending` 处理（不误报「已同步」）。
  static EntitySyncState fromCode(int? code) => switch (code) {
        0 => EntitySyncState.synced,
        1 => EntitySyncState.pending,
        2 => EntitySyncState.localOnly,
        3 => EntitySyncState.conflict,
        4 => EntitySyncState.failed,
        _ => EntitySyncState.pending,
      };

  /// 中文名（界面与文案的**单一来源**）。
  String get label => switch (this) {
        EntitySyncState.synced => '已同步',
        EntitySyncState.pending => '待上传',
        EntitySyncState.localOnly => '仅本地',
        EntitySyncState.conflict => '冲突',
        EntitySyncState.failed => '同步失败',
      };

  /// 是否已同步（界面据此取极低视觉权重）。
  bool get isSynced => this == EntitySyncState.synced;

  /// 是否为「周期上行」的状态 —— 上行批次据此从库中取舍（状态即队列，ADR-019 决策 2）。
  ///
  /// `failed` 一并纳入：它就是「本轮失败、下轮照旧重试」的语义，否则失败项只能靠用户手点重试。
  ///
  /// 是否默认参与周期上行（`localOnly` 也在列：新建的笔记 / 笔记本必须及时上传）；
  /// 「用户选择以云端为准」的例外由行上的 `sync_hold` 列表述（见 `NoteRepository`）。
  bool get needsUpload => switch (this) {
        EntitySyncState.pending ||
        EntitySyncState.localOnly ||
        EntitySyncState.conflict ||
        EntitySyncState.failed =>
          true,
        EntitySyncState.synced => false,
      };

  /// 界面「需要关注」的状态（非已同步）：角标 / 汇总 / 逐项清单据此取舍。
  bool get needsAttention => !isSynced;

  /// 界面是否提供「立即上传 / 重试」入口（`已同步` 与 `冲突` 另行处理：
  /// 前者无需操作，后者需先尝试自动合并 / 解锁加密笔记本）。
  bool get offersManualUpload => switch (this) {
        EntitySyncState.pending ||
        EntitySyncState.localOnly ||
        EntitySyncState.failed =>
          true,
        EntitySyncState.synced || EntitySyncState.conflict => false,
      };
}

/// 周期上行批次选取的状态集合（SQL `IN` 用）。
const List<int> kUploadableSyncStates = [1, 2, 3, 4];

/// 「需要关注」（非已同步）的状态集合 —— 角标与逐项清单用。
const List<int> kUnsyncedSyncStates = [1, 2, 3, 4];

/// 同步状态的承载实体类别（→ 表名）。
///
/// 三类实体共用同一套状态语义与列定义（`sync_state` / `sync_error` /
/// `sync_error_at` / `sync_checked_at`），故只在这里维护一次表名映射。
enum SyncEntityKind {
  note('notes'),
  notebook('notebooks'),
  tag('tags');

  const SyncEntityKind(this.table);

  /// 该类别对应的 SQLite 表名。
  final String table;
}
