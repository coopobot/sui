/// 时间呈现的**共享 helper**（M15 / FR-74 / ui-spec §26.2「时间双格式」）。
///
/// 抽取动机：`revision_panel.dart` 的 `_formatTime` 与 `note_list.dart` 的
/// `_relativeTime` 曾是**两份私有实现**，属性面板需要同一口径的第三份——
/// 三处若各写一份必然漂移（同一时间在列表里「3 天前」、在属性面板里「72 小时前」）。
///
/// 统一口径（取两处实现的**并集**，`note_list` 的语义为准）：
/// * 未来时间（`diff.isNegative`）与 1 分钟内 → `刚刚`；
/// * < 1 小时 → `N 分钟前`；< 1 天 → `N 小时前`；< 7 天 → `N 天前`；
/// * ≥ 7 天 → 回落 `yyyy-MM-dd`（相对形式会变成一长串数字，反而不好读）。
///
/// 两个函数都是**纯函数**，`now` 可注入（测试据此断言确定文案，不依赖真实时钟）。
library;

/// 本地绝对时间：`2026-10-15 14:03`；[withSeconds] 为真时附秒（`2026-10-15 14:03:05`）。
///
/// 展示口径为**本地时间**（`toLocal()`），与「创建时间 / 上次修改时间」的用户直觉一致。
String formatLocalDateTime(DateTime dt, {bool withSeconds = false}) {
  final local = dt.toLocal();
  final base = '${formatLocalDate(local)} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  if (!withSeconds) return base;
  return '$base:${local.second.toString().padLeft(2, '0')}';
}

/// 本地日期：`2026-10-15`（相对时间超 7 天的回落形态）。
String formatLocalDate(DateTime dt) {
  final local = dt.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// 相对时间：`刚刚` / `3 分钟前` / `2 小时前` / `5 天前`，超 7 天回落 `2026-10-15`。
///
/// [now] 为「现在」的注入点，缺省 [DateTime.now]；测试传入固定值即可断言确定文案。
String formatRelativeTime(DateTime dt, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(dt);
  if (diff.isNegative) return '刚刚';
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return formatLocalDate(dt);
}
