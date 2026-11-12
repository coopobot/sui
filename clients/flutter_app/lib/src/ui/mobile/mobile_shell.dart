import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart';

import '../../app_version.dart';
import '../app_controller.dart';
import '../appearance/app_palette.dart';
import '../markdown_editor.dart';
import '../note_editor.dart';
import '../note_list.dart';
import '../notebook_tree.dart';
import '../note_properties_panel.dart';
import '../note_shell.dart';
import '../../platform/url_opener.dart';
import '../revision_panel.dart';
import '../settings_dialog.dart';
import '../time_format.dart';
import 'mine_panels.dart';
import 'new_notebook_page.dart';

/// 窄屏（`maxWidth < 900`）根壳：底部五标签 + FAB + 编辑页（M19 / FR-111\~FR-116）。
///
/// 设计口径见 `product/ui-spec.md` §31、详细设计
/// `technology/design/low-level-design/mobile-shell.md`。
/// **桌面宽屏不走本文件**——`NoteShell` 的 `_WideLayout` 一行不改。
class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

/// 壳层聚合计数（归档 / 回收站 / 全部）。只在初始化、切 Tab、退出编辑时刷新。
///
/// 收件箱篇数**不在此聚合**：底部导航不显示收件箱角标（AC-648），篇数只在收件箱页副标题呈现。
class MobileViewCounts {
  const MobileViewCounts({
    this.archived = 0,
    this.trash = 0,
    this.total = 0,
  });

  final int archived;
  final int trash;
  final int total;

  static const zero = MobileViewCounts();
}

class _NotesFilter {
  const _NotesFilter({this.notebookId, this.tags = const [], this.query = ''});

  final String? notebookId;
  final List<String> tags;
  final String query;
}

class _MobileShellState extends State<MobileShell> {
  static const _tabNotes = 0;
  static const _tabInbox = 1;
  static const _tabNotebooks = 2;
  static const _tabTags = 3;

  int _tab = _tabNotes;
  MobileViewCounts _counts = MobileViewCounts.zero;
  _NotesFilter _savedFilter = const _NotesFilter();
  bool _hideFab = false;
  String? _lastSelectedNoteId;

  /// 上一次已处理的系统返回时刻（M19 模拟器实测：Android 16 可能对同一次返回手势
  /// 派发两次 `popRoute`，第一次关闭编辑页、第二次会把应用退出）。
  /// 仅在「已无处可退」准备退出应用时用作去抖；编辑页 / 面板的逐级关闭不受影响。
  DateTime? _lastBackHandledAt;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _lastSelectedNoteId = controller.selectedNoteId;
    controller.addListener(_onControllerChanged);
    unawaited(_refreshCounts());
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// 只在「从编辑页返回」时刷新角标，避免编辑输入路径触发额外查询。
  void _onControllerChanged() {
    final selected = controller.selectedNoteId;
    if (_lastSelectedNoteId != null && selected == null) {
      unawaited(_refreshCounts());
    }
    _lastSelectedNoteId = selected;
  }

  Future<void> _refreshCounts() async {
    final counts = await controller.loadViewCounts();
    if (!mounted) return;
    setState(() {
      _counts = MobileViewCounts(
        archived: counts.archived,
        trash: counts.trash,
        total: counts.total,
      );
    });
  }

  _NotesFilter _currentFilter() => _NotesFilter(
        notebookId: controller.selectedNotebookId,
        tags: controller.selectedTagNames,
        query: controller.query,
      );

  Future<void> _selectTab(int index) async {
    if (index == _tab) {
      // 再点「笔记」：若当前是收件箱 / 归档 / 回收站，回到全部笔记（BR-112.3）。
      if (index == _tabNotes &&
          (controller.inboxMode ||
              controller.archivedView ||
              controller.trashView)) {
        await _clearFilter();
      }
      return;
    }
    if (_tab == _tabNotes) _savedFilter = _currentFilter();
    setState(() => _tab = index);
    switch (index) {
      case _tabNotes:
        await _restoreNotesFilter();
        break;
      case _tabInbox:
        controller.search('');
        controller.selectInbox();
        break;
      case _tabTags:
        unawaited(controller.refreshTagSummaries());
        break;
      default:
        break;
    }
    unawaited(_refreshCounts());
  }

  Future<void> _restoreNotesFilter() async {
    if (!controller.inboxMode &&
        !controller.archivedView &&
        !controller.trashView) {
      return;
    }
    await controller.selectNotebook(_savedFilter.notebookId,
        selectFirstNote: false);
    controller.clearTags();
    if (_savedFilter.query.isNotEmpty) controller.search(_savedFilter.query);
    for (final tag in _savedFilter.tags) {
      if (!controller.selectedTagNames.contains(tag)) controller.toggleTag(tag);
    }
  }

  Future<void> _clearFilter() async {
    _savedFilter = const _NotesFilter();
    controller.search('');
    controller.clearTags();
    await controller.selectNotebook(null, selectFirstNote: false);
    if (mounted) setState(() => _tab = _tabNotes);
  }

  Future<void> _openNotebook(String id) async {
    _savedFilter = _currentFilter();
    await controller.selectNotebook(id, selectFirstNote: false);
    if (!mounted) return;
    setState(() => _tab = _tabNotes);
  }

  Future<void> _openAllNotes() async {
    _savedFilter = const _NotesFilter();
    controller.search('');
    controller.clearTags();
    await controller.selectNotebook(null, selectFirstNote: false);
    if (!mounted) return;
    setState(() => _tab = _tabNotes);
  }

  Future<void> _openInbox() async {
    await _selectTab(_tabInbox);
  }

  void _openTags() {
    unawaited(controller.refreshTagSummaries());
    setState(() => _tab = _tabTags);
  }

  /// 标签「查看 N 篇」：保留当前标签筛选，切回笔记 Tab（不再恢复旧筛选）。
  void _showTagResults() {
    _savedFilter = _currentFilter();
    setState(() => _tab = _tabNotes);
  }

  /// 归档面板点开一条笔记：切回「笔记」Tab 并选中。
  Future<void> _openNoteFromPanel(String id) async {
    controller.selectNote(id);
    if (!mounted) return;
    setState(() => _tab = _tabNotes);
  }

  Future<void> _newNote() async {
    if (controller.inboxMode ||
        controller.archivedView ||
        controller.trashView ||
        controller.hasTagFilter) {
      controller.search('');
      controller.clearTags();
      await controller.selectNotebook(null, selectFirstNote: false);
    }
    await controller.createNote();
  }

  Future<void> _newNotebook() async {
    final nb = await Navigator.of(context).push<Notebook>(
      MaterialPageRoute(
        builder: (_) => MobileNewNotebookPage(controller: controller),
      ),
    );
    if (nb == null || !mounted) return;
    setState(() {
      _tab = _tabNotebooks;
      _hideFab = true;
    });
    final bar = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已创建「${nb.name}」'),
        action: SnackBarAction(
          label: '新建笔记',
          onPressed: () => unawaited(controller.createNote(notebookId: nb.id)),
        ),
      ),
    );
    unawaited(bar.closed.then((_) {
      if (mounted) setState(() => _hideFab = false);
    }));
    unawaited(_refreshCounts());
  }

  /// 系统返回的统一处理（M19 / FR-116 / ADR-041）。
  ///
  /// 顺序：属性面板 → 版本历史 → 编辑页 → 非「笔记」Tab → 退出应用。
  /// 编辑页与各面板不再是独立的 Navigator 路由（窄屏是同一路由内的条件渲染），
  /// 因此由壳层统一接管，不依赖 `PopScope` 的路由出栈。
  void _handleSystemBack() {
    final now = DateTime.now();
    final recent = _lastBackHandledAt != null &&
        now.difference(_lastBackHandledAt!) < const Duration(milliseconds: 600);
    _lastBackHandledAt = now;

    if (controller.selectedNoteId != null) {
      if (controller.showPropertiesPanel) {
        controller.setPropertiesPanelVisible(false);
        return;
      }
      if (controller.showRevisionPanel) {
        controller.setRevisionPanelVisible(false);
        return;
      }
      controller.selectNote(null);
      return;
    }
    if (_tab != _tabNotes) {
      unawaited(_selectTab(_tabNotes));
      return;
    }
    // 已在「笔记」Tab 根层：同一次返回手势的重复事件不再退出应用。
    if (recent) return;
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 始终由壳层接管：Android 16 上 if 条件渲染的「编辑页」没有独立路由，
      // `canPop: true` 会把返回直接冒泡成退出应用（模拟器实测）。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleSystemBack();
      },
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.selectedNoteId != null) {
            return _MobileEditorPage(controller: controller);
          }
          return _buildTabs(context);
        },
      ),
    );
  }

  Widget _buildTabs(BuildContext context) {
    final showTagBar = _tab == _tabTags && controller.hasTagFilter;
    // 笔记 / 收件箱共用**同一个**列表页（只换标题与筛选），保活时搜索与滚动天然共享；
    // 其余 Tab 的 IndexedStack 下标顺延一位。
    final pageIndex = _tab <= _tabInbox ? 0 : _tab - 1;
    return Scaffold(
      body: IndexedStack(
        index: pageIndex,
        children: [
          _MobileNotesPage(
            controller: controller,
            titleMode: _tab == _tabInbox
                ? _NotesTitleMode.inbox
                : _NotesTitleMode.notes,
            onOpenNotebooks: _openNotebooksTab,
            onOpenTags: _openTags,
            onClearFilter: _clearFilter,
          ),
          _MobileNotebooksPage(
            controller: controller,
            counts: _counts,
            onOpenNotebook: _openNotebook,
            onOpenAllNotes: _openAllNotes,
            onOpenInbox: _openInbox,
            onNewNotebook: _newNotebook,
          ),
          _MobileTagsPage(
            controller: controller,
            onViewResults: _showTagResults,
          ),
          _MobileMinePage(
            controller: controller,
            counts: _counts,
            onOpenNote: _openNoteFromPanel,
          ),
        ],
      ),
      floatingActionButton: _buildFab(context),
      bottomNavigationBar: showTagBar
          ? _MobileTagActionBar(
              controller: controller,
              onClear: controller.clearTags,
              onView: _showTagResults,
            )
          : MobileNavBar(
              index: _tab,
              onSelected: (index) => unawaited(_selectTab(index)),
            ),
    );
  }

  /// 从笔记 Tab 的范围胶囊进入笔记本 Tab（不是筛选动作）。
  void _openNotebooksTab() => setState(() => _tab = _tabNotebooks);

  Widget? _buildFab(BuildContext context) {
    if (_hideFab) return null;
    final scheme = Theme.of(context).colorScheme;
    switch (_tab) {
      case _tabNotes:
        return FloatingActionButton(
          key: const ValueKey('mobile-fab'),
          tooltip: '新建笔记',
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          onPressed: () => unawaited(_newNote()),
          child: const Icon(Icons.add),
        );
      case _tabNotebooks:
        return FloatingActionButton(
          key: const ValueKey('mobile-fab'),
          tooltip: '新建笔记本',
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          onPressed: () => unawaited(_newNotebook()),
          child: const Icon(Icons.create_new_folder_outlined),
        );
      default:
        return null;
    }
  }
}

// ---------------------------------------------------------------------------
// 底部导航
// ---------------------------------------------------------------------------

/// 底部五标签（FR-111）：高 64 + 安全区，活动项只用品牌绿图标 / 文字。
class MobileNavBar extends StatelessWidget {
  const MobileNavBar({
    super.key,
    required this.index,
    required this.onSelected,
  });

  final int index;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = SuiAppearance.of(context).palette;
    return Material(
      color: palette.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: NavigationBarTheme(
            data: NavigationBarThemeData(
              backgroundColor: Colors.transparent,
              indicatorColor: Colors.transparent,
              labelBehavior:
                  NavigationDestinationLabelBehavior.alwaysShow,
              iconTheme: WidgetStateProperty.resolveWith(
                (states) => IconThemeData(
                  size: 22,
                  color: states.contains(WidgetState.selected)
                      ? scheme.primary
                      : palette.outline,
                ),
              ),
              labelTextStyle: WidgetStateProperty.resolveWith(
                (states) => TextStyle(
                  fontSize: 10,
                  fontWeight: states.contains(WidgetState.selected)
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: states.contains(WidgetState.selected)
                      ? scheme.primary
                      : palette.outline,
                ),
              ),
            ),
            child: NavigationBar(
              height: 64,
              selectedIndex: index,
              onDestinationSelected: onSelected,
              destinations: const [
                NavigationDestination(
                  key: ValueKey('mobile-tab-0'),
                  icon: Icon(Icons.notes_outlined),
                  selectedIcon: Icon(Icons.notes),
                  label: '笔记',
                ),
                NavigationDestination(
                  key: ValueKey('mobile-tab-1'),
                  icon: Icon(Icons.inbox_outlined),
                  selectedIcon: Icon(Icons.inbox),
                  label: '收件箱',
                ),
                NavigationDestination(
                  key: ValueKey('mobile-tab-2'),
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: '笔记本',
                ),
                NavigationDestination(
                  key: ValueKey('mobile-tab-3'),
                  icon: Icon(Icons.label_outline),
                  selectedIcon: Icon(Icons.label),
                  label: '标签',
                ),
                NavigationDestination(
                  key: ValueKey('mobile-tab-4'),
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: '我的',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 公共头部 / 同步胶囊
// ---------------------------------------------------------------------------

/// 移动端页面头部：大标题 24/700 + 副标题 12 + 右侧同步状态胶囊（FR-112）。
class MobilePageHeader extends StatelessWidget {
  const MobilePageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = SuiAppearance.of(context).palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: palette.outline),
          ),
        ],
      ),
    );
  }
}

/// 顶栏同步状态胶囊：点按 = 同步 / 未配置时进同步设置。
class SyncStatusPill extends StatelessWidget {
  const SyncStatusPill({super.key, required this.controller, this.dense = false});

  final AppController controller;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = controller.syncState;
    final (label, color) = switch (state) {
      SyncState.unconfigured => ('仅本地', scheme.outline),
      SyncState.idle => ('已同步', scheme.primary),
      SyncState.syncing => ('同步中', scheme.primary),
      SyncState.error => ('同步失败', scheme.error),
    };
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        if (state == SyncState.unconfigured) {
          unawaited(showSettingsDialog(context, controller,
              section: SettingsSection.sync));
        } else {
          unawaited(controller.syncNow());
        }
      },
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 笔记 / 收件箱
// ---------------------------------------------------------------------------

enum _NotesTitleMode { notes, inbox }

class _MobileNotesPage extends StatelessWidget {
  const _MobileNotesPage({
    required this.controller,
    required this.titleMode,
    required this.onOpenNotebooks,
    required this.onOpenTags,
    required this.onClearFilter,
  });

  final AppController controller;
  final _NotesTitleMode titleMode;
  final VoidCallback onOpenNotebooks;
  final VoidCallback onOpenTags;
  final Future<void> Function() onClearFilter;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MobilePageHeader(
            title: _title(),
            subtitle: _subtitle(),
            trailing: SyncStatusPill(controller: controller),
          ),
          Expanded(
            child: NoteList(
              controller: controller,
              showHeaderTitle: false,
              filterBar: _filterBar(context),
            ),
          ),
        ],
      ),
    );
  }

  String? get _notebookName {
    final id = controller.selectedNotebookId;
    if (id == null) return null;
    for (final nb in controller.notebooks) {
      if (nb.id == id) return nb.name;
    }
    return null;
  }

  String _title() {
    if (titleMode == _NotesTitleMode.inbox) return '收件箱';
    if (controller.trashView) return '回收站';
    if (controller.archivedView) return '归档';
    if (controller.hasTagFilter) {
      return controller.selectedTagNames.map((t) => '#$t').join(' ');
    }
    return _notebookName ?? '全部笔记';
  }

  String _subtitle() {
    final count = controller.notes.length;
    if (titleMode == _NotesTitleMode.inbox) {
      return '$count 篇待整理 · 来自网页剪藏';
    }
    if (controller.trashView) return '$count 篇已删除 · 可还原';
    if (controller.archivedView) return '$count 篇归档笔记';
    if (controller.hasTagFilter) {
      final tags = controller.selectedTagNames;
      if (tags.length == 1) return '标签 · 共 $count 篇';
      return '与 ${tags.skip(1).map((t) => '#$t').join(' ')} 取交集 · 共 $count 篇';
    }
    if (controller.selectedNotebookId != null) {
      final path = notebookPathLabel(controller, controller.selectedNotebookId);
      // 顶层笔记本的路径就是名称本身：不再重复成「Cork · 1 篇笔记」。
      return path == _notebookName ? '$count 篇笔记' : '$path · $count 篇笔记';
    }
    return '$count 篇笔记 · ${controller.notebooks.length} 个笔记本';
  }

  Widget _filterBar(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    final chips = <Widget>[];
    if (titleMode == _NotesTitleMode.inbox ||
        controller.archivedView ||
        controller.trashView) {
      chips.add(_staticPill(
        context,
        icon: titleMode == _NotesTitleMode.inbox
            ? Icons.inbox_outlined
            : controller.trashView
                ? Icons.delete_outline
                : Icons.archive_outlined,
        label: titleMode == _NotesTitleMode.inbox
            ? '收件箱'
            : controller.trashView
                ? '回收站'
                : '归档',
      ));
      chips.add(ActionChip(
        key: const ValueKey('mobile-clear-filter'),
        avatar: const Icon(Icons.filter_alt_off_outlined, size: 16),
        label: const Text('清除筛选'),
        onPressed: () => unawaited(onClearFilter()),
      ));
    } else {
      chips.add(ActionChip(
        key: const ValueKey('mobile-scope'),
        avatar: const Icon(Icons.folder_outlined, size: 16),
        label: Text(_notebookName ?? '全部笔记'),
        onPressed: onOpenNotebooks,
      ));
      chips.add(_SortChip(controller: controller));
      for (final tag in controller.selectedTagNames) {
        chips.add(InputChip(
          label: Text('#$tag'),
          onDeleted: () => controller.toggleTag(tag),
        ));
      }
      chips.add(ActionChip(
        key: const ValueKey('mobile-tags'),
        avatar: const Icon(Icons.label_outline, size: 16),
        label: const Text('+ 标签'),
        onPressed: onOpenTags,
      ));
    }
    final scheme = Theme.of(context).colorScheme;
    // 显式给全 ChipTheme：只 copyWith(labelStyle) 会让标签文字丢失前景色
    // （实机表现为浅底上的白字、几乎不可见，M19 模拟器实测）。
    final chipTheme = ChipThemeData(
      backgroundColor: palette.containerLow,
      selectedColor: scheme.primary.withValues(alpha: 0.12),
      disabledColor: palette.containerLow,
      side: BorderSide(color: palette.divider),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      labelStyle: TextStyle(fontSize: 12, color: scheme.onSurface),
      secondaryLabelStyle: TextStyle(fontSize: 12, color: scheme.onSurface),
      iconTheme: IconThemeData(size: 16, color: palette.outline),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (final chip in chips)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Theme(
                data: Theme.of(context).copyWith(chipTheme: chipTheme),
                child: chip,
              ),
            ),
        ],
      ),
    );
  }

  Widget _staticPill(BuildContext context,
      {required IconData icon, required String label}) {
    final palette = SuiAppearance.of(context).palette;
    return Chip(
      avatar: Icon(icon, size: 16, color: palette.outline),
      label: Text(label),
    );
  }
}

/// 排序胶囊（与桌面 `NoteSortButton` 共用 `noteSortLabel`）。
class _SortChip extends StatelessWidget {
  const _SortChip({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<NoteSortMode>(
      initialValue: controller.sortMode,
      onSelected: controller.setSortMode,
      itemBuilder: (_) => [
        for (final mode in NoteSortMode.values)
          PopupMenuItem<NoteSortMode>(
            value: mode,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: controller.sortMode == mode
                      ? const Icon(Icons.check, size: 18)
                      : null,
                ),
                Text(noteSortLabel(mode)),
              ],
            ),
          ),
      ],
      child: Chip(
        avatar: const Icon(Icons.sort, size: 16),
        label: Text(noteSortLabel(controller.sortMode)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 笔记本
// ---------------------------------------------------------------------------

class _MobileNotebooksPage extends StatelessWidget {
  const _MobileNotebooksPage({
    required this.controller,
    required this.counts,
    required this.onOpenNotebook,
    required this.onOpenAllNotes,
    required this.onOpenInbox,
    required this.onNewNotebook,
  });

  final AppController controller;
  final MobileViewCounts counts;
  final ValueChanged<String> onOpenNotebook;
  final Future<void> Function() onOpenAllNotes;
  final Future<void> Function() onOpenInbox;
  final Future<void> Function() onNewNotebook;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MobilePageHeader(
            title: '笔记本',
            subtitle: '${controller.notebooks.length} 个笔记本 · ${counts.total} 篇',
            trailing: SyncStatusPill(controller: controller),
          ),
          Expanded(
            child: NotebookTree(
              controller: controller,
              compact: true,
              onOpenNotebook: onOpenNotebook,
              onOpenAllNotes: () => unawaited(onOpenAllNotes()),
              onOpenInbox: () => unawaited(onOpenInbox()),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 标签
// ---------------------------------------------------------------------------

class _MobileTagsPage extends StatelessWidget {
  const _MobileTagsPage({required this.controller, required this.onViewResults});

  final AppController controller;
  final VoidCallback onViewResults;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = SuiAppearance.of(context).palette;
    final tags = controller.tagSummaries;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MobilePageHeader(
            title: '标签',
            subtitle: '${tags.length} 个标签',
            trailing: controller.hasTagFilter
                ? TextButton(
                    onPressed: controller.clearTags,
                    child: const Text('✕ 退出多选'),
                  )
                : null,
          ),
          Expanded(
            child: tags.isEmpty
                ? Center(
                    child: Text('暂无标签',
                        style: TextStyle(color: palette.outline)),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisExtent: 64,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: tags.length,
                    itemBuilder: (context, i) {
                      final tag = tags[i];
                      final selected =
                          controller.selectedTagNames.contains(tag.name);
                      return InkWell(
                        key: ValueKey('mobile-tag-${tag.name}'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: tag.noteCount == 0
                            ? null
                            : () => controller.toggleTag(tag.name),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: selected
                                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                                : palette.containerLow,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: selected
                                  ? theme.colorScheme.primary
                                  : palette.divider,
                            ),
                          ),
                          child: Stack(
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '#${tag.name}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${tag.noteCount} 篇',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: palette.outline),
                                  ),
                                ],
                              ),
                              if (selected)
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  child: Icon(Icons.check_circle,
                                      size: 16,
                                      color: theme.colorScheme.primary),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 标签多选操作条（替代底部主导航，FR-115）。
class _MobileTagActionBar extends StatelessWidget {
  const _MobileTagActionBar({
    required this.controller,
    required this.onClear,
    required this.onView,
  });

  final AppController controller;
  final VoidCallback onClear;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    return Material(
      color: palette.surface,
      child: SafeArea(
        top: false,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: palette.divider)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '已选 ${controller.selectedTagNames.length} 个标签',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    Text('取交集',
                        style: TextStyle(
                            fontSize: 11, color: palette.outline)),
                  ],
                ),
              ),
              TextButton(onPressed: onClear, child: const Text('清空')),
              FilledButton(
                key: const ValueKey('mobile-tag-view'),
                onPressed: onView,
                child: Text('查看 ${controller.notes.length} 篇'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 我的
// ---------------------------------------------------------------------------

class _MobileMinePage extends StatelessWidget {
  const _MobileMinePage({
    required this.controller,
    required this.counts,
    required this.onOpenNote,
  });

  final AppController controller;
  final MobileViewCounts counts;
  final Future<void> Function(String id) onOpenNote;

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    final theme = Theme.of(context);
    final lastSynced = controller.lastSyncedAt;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MobilePageHeader(
            title: '我的',
            subtitle: '本地优先 · 数据自持',
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _push(
                      context,
                      MineAccountPage(controller: controller),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: palette.containerLow,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: palette.divider),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 24,
                            backgroundColor:
                                theme.colorScheme.primary.withValues(alpha: 0.12),
                            child: Icon(Icons.person,
                                color: theme.colorScheme.primary),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('随手记 Sui',
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(
                                  lastSynced == null
                                      ? '${_syncLabel(controller)} · 上次同步 —'
                                      : '${_syncLabel(controller)} · 上次同步 '
                                          '${formatRelativeTime(lastSynced)}',
                                  style: TextStyle(
                                      fontSize: 11, color: palette.outline),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right, color: palette.outline),
                        ],
                      ),
                    ),
                  ),
                ),
                const _GroupLabel('同步'),
                _MineSyncRow(controller: controller),
                const _GroupLabel('内容'),
                _MineRow(
                  icon: Icons.archive_outlined,
                  title: '归档',
                  value: '${counts.archived}',
                  onTap: () => _push(
                    context,
                    MineArchivePage(
                      controller: controller,
                      onOpenNote: onOpenNote,
                    ),
                  ),
                ),
                _MineRow(
                  icon: Icons.delete_outline,
                  title: '回收站',
                  value: '${counts.trash}',
                  onTap: () => _push(
                    context,
                    MineTrashPage(controller: controller),
                  ),
                ),
                _MineRow(
                  icon: Icons.sd_storage_outlined,
                  title: '附件缓存',
                  value: '上限 ${_formatBytes(controller.cacheLimitBytes)}',
                  onTap: () => _push(
                    context,
                    MineCachePage(controller: controller),
                  ),
                ),
                const _GroupLabel('通用'),
                _MineSettingRow(
                  label: '默认编辑模式',
                  value: _modeLabel(controller.editorMode),
                  onTap: () => _pickEditorMode(context),
                ),
                const _GroupLabel('应用'),
                _MineRow(
                  icon: Icons.palette_outlined,
                  title: '外观',
                  value: _themeLabel(controller.themeMode),
                  onTap: () => _push(
                    context,
                    MineAppearancePage(controller: controller),
                  ),
                ),
                _MineRow(
                  icon: Icons.menu_book_outlined,
                  title: '使用文档',
                  value: '在线文档 ↗',
                  onTap: () => _openDocs(context),
                ),
                _MineRow(
                  icon: Icons.info_outline,
                  title: '关于',
                  value: '版本 $kAppVersion',
                  onTap: () => _push(context, const MineAboutPage()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickEditorMode(BuildContext context) async {
    final selected = await showModalBottomSheet<EditorMode>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in EditorMode.values)
              ListTile(
                title: Text(_modeLabel(mode)),
                trailing: controller.editorMode == mode
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(mode),
              ),
          ],
        ),
      ),
    );
    if (selected != null) controller.setEditorMode(selected);
  }

  Future<void> _openDocs(BuildContext context) async {
    final ok = await openExternalUrl('https://coopobot.github.io/sui/');
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开浏览器，请访问 https://coopobot.github.io/sui/')),
      );
    }
  }

  static String _syncLabel(AppController controller) => switch (controller.syncState) {
        SyncState.unconfigured => '仅本地',
        SyncState.idle => '已同步',
        SyncState.syncing => '正在同步…',
        SyncState.error => '同步失败',
      };

  static String _modeLabel(EditorMode mode) => switch (mode) {
        EditorMode.formatted => '格式',
        EditorMode.source => '源码',
        EditorMode.preview => '预览',
      };

  static String _themeLabel(ThemeMode mode) => switch (mode) {
        ThemeMode.light => '浅色',
        ThemeMode.dark => '深色',
        ThemeMode.system => '跟随系统',
      };

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    return '${(bytes / 1024).round()} KB';
  }
}

/// 「我的」同步行：一行内显示状态 + 操作（MB-M00）。
class _MineSyncRow extends StatelessWidget {
  const _MineSyncRow({required this.controller});

  final AppController controller;

  /// 同步行 = 顶栏云按钮的同一口径：**就地同步**，不打开任何二级页面。
  ///
  /// 未连接时 `syncNow()` 会静默返回（没有 client），因此这里给一条提示，
  /// 引导用户从上方账户卡进入「账号」；同步行本身不导航。
  void _handleSyncTap(BuildContext context) {
    if (!controller.syncConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未连接服务端，请先在「账号」中连接')),
      );
      return;
    }
    unawaited(controller.syncNow());
  }

  @override
  Widget build(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.syncState;
        final isError = state == SyncState.error;
        final label = switch (state) {
          SyncState.unconfigured => '仅本地',
          SyncState.idle => '已同步',
          SyncState.syncing => '正在同步…',
          SyncState.error => '同步失败',
        };
        final detail = isError
            ? (controller.syncError ?? '无法连接服务端')
            : (controller.lastSyncedAt == null
                ? null
                : '上次同步 ${formatRelativeTime(controller.lastSyncedAt!)}');
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Material(
            color: palette.containerLow,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _handleSyncTap(context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: state == SyncState.unconfigured
                            ? palette.outline
                            : (isError ? scheme.error : scheme.primary),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500)),
                          if (detail != null)
                            Text(
                              detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: palette.outline),
                            ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: state == SyncState.syncing
                          ? null
                          : () => _handleSyncTap(context),
                      child: Text(state == SyncState.syncing ? '同步中' : '立即同步'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 单列通用设置行（无图标；有 onTap 才显示 `›`）。
class _MineSettingRow extends StatelessWidget {
  const _MineSettingRow({
    required this.label,
    required this.value,
    this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    return SizedBox(
      height: 52,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(label, style: const TextStyle(fontSize: 15)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value,
                style: TextStyle(fontSize: 11, color: palette.outline)),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: palette.outline),
            ],
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: palette.outline,
        ),
      ),
    );
  }
}

class _MineRow extends StatelessWidget {
  const _MineRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    return SizedBox(
      height: 56,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Icon(icon, size: 22),
        title: Text(title, style: const TextStyle(fontSize: 15)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (value.isNotEmpty)
              Text(value,
                  style: TextStyle(fontSize: 11, color: palette.outline)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: palette.outline),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 编辑页
// ---------------------------------------------------------------------------

/// 窄屏编辑页（FR-116）：一行顶栏 + `NoteEditor(compactDock: true)`。
///
/// 修订历史 / 属性面板仍为**整页推入**（与桌面右侧栏能力一致），系统返回先关面板、
/// 再退出编辑（BR-12.3 / AC-137 口径不变）。
class _MobileEditorPage extends StatelessWidget {
  const _MobileEditorPage({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final editorOpen = controller.selectedNoteId != null;
    final showProperties = editorOpen && controller.showPropertiesPanel;
    final showRevisions =
        editorOpen && !showProperties && controller.showRevisionPanel;
    // 系统返回由 `MobileShell._handleSystemBack` 统一接管（见其注释）。
    return Scaffold(
        appBar: AppBar(
          title: Text(
            showProperties
                ? '属性'
                : (showRevisions
                    ? '版本历史'
                    : _editorBreadcrumb(controller)),
          ),
          leading: showProperties
              ? BackButton(
                  onPressed: () => controller.setPropertiesPanelVisible(false),
                )
              : showRevisions
                  ? BackButton(
                      onPressed: () => controller.setRevisionPanelVisible(false),
                    )
                  : editorOpen
                      ? BackButton(
                          onPressed: () {
                            controller.setRevisionPanelVisible(false);
                            controller.setPropertiesPanelVisible(false);
                            controller.selectNote(null);
                          },
                        )
                      : null,
          actions: [
            if (controller.hasUnlockedNotebook)
              IconButton(
                tooltip: '立即锁定加密笔记本',
                icon: const Icon(Icons.lock_outline),
                onPressed: () => controller.lockAllNotebooks(),
              ),
            SyncStatusPill(controller: controller, dense: true),
            const SizedBox(width: 8),
          ],
        ),
        body: showProperties
            ? NotePropertiesPanel(
                key: ValueKey(controller.selectedNoteId),
                noteId: controller.selectedNoteId!,
              )
            : showRevisions
                ? RevisionPanel(
                    key: ValueKey(controller.selectedNoteId),
                    noteId: controller.selectedNoteId!,
                  )
                : editorOpen
                    ? (controller.selectedNoteLocked
                        ? LockedNotePane(controller: controller)
                        : NoteEditor(
                            key: ValueKey(controller.selectedNoteId),
                            compactDock: true,
                          ))
                    : const SizedBox.shrink(),
    );
  }
}

/// 编辑页顶栏的面包屑（M19 / FR-116）：工作 / 产品设计；不在笔记本时显示「笔记」。
String _editorBreadcrumb(AppController controller) {
  final notebookId = controller.selectedNoteSummary?.note.notebookId;
  if (notebookId == null) return '笔记';
  final path = notebookPathLabel(controller, notebookId);
  return path == '顶层' ? '笔记' : path;
}
