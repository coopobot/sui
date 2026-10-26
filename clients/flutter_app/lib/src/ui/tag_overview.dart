import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import 'app_controller.dart';

/// 打开标签总览（FR-22）。
///
/// 「全部标签」入口在左栏内与「视图」菜单中各有一处（BR-40.5 / AC-115），
/// 故把「刷新标签汇总 + 推入总览页」抽成公共函数，两处**同源同效**，避免实现分叉。
void openTagOverview(BuildContext context, AppController controller) {
  controller.refreshTagSummaries();
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => TagOverview(controller: controller),
      fullscreenDialog: true,
    ),
  );
}

/// 标签总览面板（FR-22）：全部标签 + 关联数量 + 多选筛选 + 排序切换。
///
/// 以对话框形式从笔记本树的「全部标签」入口打开；点击标签即在笔记列表中
/// 按标签筛选（多选取交集，BR-22.2），已选标签高亮并可再次点击取消。
class TagOverview extends StatelessWidget {
  const TagOverview({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final summaries = controller.tagSummaries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('全部标签'),
        actions: [
          PopupMenuButton<TagSortMode>(
            icon: const Icon(Icons.sort, size: 20),
            tooltip: '标签排序',
            initialValue: controller.tagSortMode,
            onSelected: controller.setTagSortMode,
            itemBuilder: (_) => [
              for (final mode in TagSortMode.values)
                PopupMenuItem<TagSortMode>(
                  value: mode,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 24,
                        child: controller.tagSortMode == mode
                            ? const Icon(Icons.check, size: 18)
                            : null,
                      ),
                      Text(_sortLabel(mode)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      body: summaries.isEmpty
          ? const Center(
              child: Text('暂无标签', style: TextStyle(color: Colors.grey)),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in summaries) _TagChip(controller: controller, s: s),
                ],
              ),
            ),
      bottomNavigationBar: controller.hasTagFilter
          ? Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '已选 ${controller.selectedTagNames.length} 个标签（取交集）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.clear, size: 18),
                    label: const Text('清空'),
                    onPressed: controller.clearTags,
                  ),
                ],
              ),
            )
          : null,
    );
  }

  static String _sortLabel(TagSortMode mode) => switch (mode) {
        TagSortMode.countDesc => '按数量降序',
        TagSortMode.nameAsc => '按名称升序',
      };
}

/// 单个标签 chip：显示 `#name (N)`，点击切换选中状态（BR-22.2）。
class _TagChip extends StatelessWidget {
  const _TagChip({required this.controller, required this.s});
  final AppController controller;
  final TagSummary s;

  @override
  Widget build(BuildContext context) {
    final selected = controller.selectedTagNames.contains(s.name);
    final empty = s.noteCount == 0;
    final scheme = Theme.of(context).colorScheme;
    return FilterChip(
      label: Text('#${s.name} (${s.noteCount})'),
      selected: selected,
      onSelected: empty ? null : (_) => controller.toggleTag(s.name),
      selectedColor: scheme.primaryContainer,
      checkmarkColor: scheme.onPrimaryContainer,
      labelStyle: TextStyle(
        color: empty ? scheme.outline : null,
      ),
    );
  }
}
