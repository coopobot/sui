import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

/// 逐项同步状态的**就地呈现**（M12 / FR-53 / ui-spec §20.1）。
///
/// 五态为**语义标签**：图标与颜色一律取既有 `ColorScheme` 的语义色，
/// 不引入新色系（ui-spec §13 / §20.1）。`已同步` 走**极低视觉权重**
/// （淡色对勾），其余四态用醒目色，使「哪些还没到云端」一眼可辨。
///
/// 本组件只负责**呈现**：状态判定与记账在 `note_core`（ADR-019）。
/// tooltip 模板是文案的**单一来源**，列表行 / 树节点 / 结果列表共用。
class SyncStatusIcon extends StatelessWidget {
  const SyncStatusIcon({
    super.key,
    required this.state,
    this.error,
    this.errorAt,
    this.checkedAt,
    this.kind,
    this.encryptedLocked = false,
    this.size = 16,
    this.dotOnly = false,
    this.onDark = false,
  });

  /// 展示用的同步状态（未配置同步时由 [displaySyncState] 收敛为 `仅本地`）。
  final EntitySyncState state;

  /// 失败 / 冲突原因（`syncError`）；`同步失败` 必须含原因（BR-53.2）。
  final String? error;

  /// 失败发生时间（`syncErrorAt`）。
  final DateTime? errorAt;

  /// 最近一次核对时间（供 `已同步` 模板；无则省略括号）。
  final DateTime? checkedAt;

  /// 实体类别：决定 `仅本地` 文案里的「该笔记本 / 该笔记 / 该标签」。
  final SyncEntityKind? kind;

  /// 加密笔记本未解锁：共性文案后追加一句（BR-53.5 / ui-spec §20.7）。
  final bool encryptedLocked;

  /// 图标边长。窄屏可降到 14。
  final double size;

  /// 窄屏降级：**只出状态点**（不显示图标轮廓，ui-spec §20.3）。
  final bool dotOnly;

  /// 深色底（左栏导航栏）：保持语义色相不变，仅**提亮**以满足 §20.2 的高对比要求。
  final bool onDark;

  /// 五态 → 图标（ui-spec §20.1 表格，逐项对齐）。
  static IconData iconOf(EntitySyncState state) => switch (state) {
        EntitySyncState.synced => Icons.check,
        EntitySyncState.pending => Icons.arrow_upward,
        EntitySyncState.localOnly => Icons.cloud_off,
        EntitySyncState.conflict => Icons.call_split,
        EntitySyncState.failed => Icons.error_outline,
      };

  /// 五态 → 颜色 role（禁止新色系）。
  static Color colorOf(ColorScheme scheme, EntitySyncState state) =>
      switch (state) {
        EntitySyncState.synced => scheme.outline,
        EntitySyncState.pending => scheme.primary,
        EntitySyncState.localOnly => scheme.tertiary,
        EntitySyncState.conflict || EntitySyncState.failed => scheme.error,
      };

  /// tooltip 模板（ui-spec §20.1，**文案单一来源**）。
  static String tooltipFor({
    required EntitySyncState state,
    String? error,
    DateTime? errorAt,
    DateTime? checkedAt,
    SyncEntityKind? kind,
    bool encryptedLocked = false,
  }) {
    final entity = switch (kind) {
      SyncEntityKind.note => '笔记',
      SyncEntityKind.notebook => '笔记本',
      SyncEntityKind.tag => '标签',
      null => '实体',
    };
    final reason = (error ?? '').trim();
    final base = switch (state) {
      EntitySyncState.synced => checkedAt == null
          ? '已同步'
          : '已同步（最近核对：${formatSyncTime(checkedAt)}）',
      EntitySyncState.pending => '待上传：本机有未上传改动，云端已知该实体',
      // BR-53.2：必须点明「云端没有该实体」。
      EntitySyncState.localOnly => '仅本地：云端没有该实体（该$entity只存在于本机）',
      EntitySyncState.conflict =>
        '冲突：云端已更新，本机也有未上传改动（${reason.isEmpty ? (encryptedLocked ? '需先解锁才能合并' : '将按既有合并策略自动合并') : reason}）',
      // BR-53.2：必须含原因与时间。
      EntitySyncState.failed =>
        '同步失败：${reason.isEmpty ? '未记录失败原因' : reason}'
            '${errorAt == null ? '' : '（${formatSyncTime(errorAt)}）'}',
    };
    return encryptedLocked ? '$base（加密笔记本，未解锁；解锁后可查看冲突详情）' : base;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = colorOf(scheme, state);
    // 深色左栏：色相不变、仅提亮（§20.2「选中 / 未选中均可辨」）。
    final color = onDark
        ? (state.isSynced ? Colors.white38 : Color.lerp(base, Colors.white, 0.4)!)
        : base;
    final tooltip = tooltipFor(
      state: state,
      error: error,
      errorAt: errorAt,
      checkedAt: checkedAt,
      kind: kind,
      encryptedLocked: encryptedLocked,
    );
    final visual = dotOnly
        ? Container(
            width: size * 0.55,
            height: size * 0.55,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          )
        : Icon(
            iconOf(state),
            size: size,
            color: color,
            // 无障碍与测试定位：语义标签即五态中文名（文案单一来源在 note_core）。
            semanticLabel: state.label,
          );
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Center(child: visual),
      ),
    );
  }
}

/// 未同步计数角标（同步设置对话框 / 「全部重新同步」入口用，ui-spec §20.5）。
///
/// 计数为 0 时**不占位**（返回零尺寸）。
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({super.key, required this.count, this.tooltip});

  final int count;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip ?? '有 $count 项尚未同步到云端',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '$count',
          style: TextStyle(fontSize: 11, color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}

/// 未配置同步时的**保守态**：本地实体一律呈现 `仅本地` 的弱化文案，
/// **不伪造「已同步」**（BR-53.6 / AC-185）。
EntitySyncState displaySyncState(
  EntitySyncState state, {
  required bool configured,
}) =>
    configured ? state : EntitySyncState.localOnly;

/// 同步时间戳的呈现（tooltip 模板用）：`MM-dd HH:mm`（本机时区）。
String formatSyncTime(DateTime dt) {
  final t = dt.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
