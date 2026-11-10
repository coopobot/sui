import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart';

import '../../app_version.dart';
import '../app_controller.dart';
import '../settings_dialog.dart';
import '../sync_settings_dialog.dart';
import '../time_format.dart';

/// 全屏二级面板的统一外壳（M19 / MB-M00 二级页）。
///
/// 头部：`←` + 17/600 标题；内容区由各面板提供；不显示底部五标签。
class MinePanelScaffold extends StatelessWidget {
  const MinePanelScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions,
  });

  final String title;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: actions,
      ),
      body: SafeArea(top: false, child: child),
    );
  }
}

/// MB-M01「账号」：服务器 / 账号 / 设备；不承载同步工具。
class MineAccountPage extends StatelessWidget {
  const MineAccountPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MinePanelScaffold(
      title: '账号',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: const [
          SyncSettingsPanel(
            showSyncTools: false,
            disconnectLabel: '退出登录',
          ),
        ],
      ),
    );
  }
}

/// MB-M06「附件缓存」。
class MineCachePage extends StatelessWidget {
  const MineCachePage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MinePanelScaffold(
      title: '附件缓存',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [CacheSettingsSection(controller: controller)],
      ),
    );
  }
}

/// MB-M07「外观」。
class MineAppearancePage extends StatelessWidget {
  const MineAppearancePage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MinePanelScaffold(
      title: '外观',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [AppearanceSettingsSection(controller: controller)],
      ),
    );
  }
}

/// MB-M10「关于」：版本 / 许可 / 隐私 / 复制；检查更新本期置灰。
class MineAboutPage extends StatelessWidget {
  const MineAboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = theme.colorScheme;
    return MinePanelScaffold(
      title: '关于',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        children: [
          Center(
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(
                'S',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: palette.primary,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '随手记 Sui',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '版本 $kAppVersion',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: palette.outline),
          ),
          const SizedBox(height: 4),
          Text(
            '自托管 · 离线优先 · 多端同步',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: palette.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            color: theme.colorScheme.surfaceContainerLow,
            child: Column(
              children: [
                ListTile(
                  enabled: false,
                  title: const Text('检查更新'),
                  trailing: Text(
                    '暂不可用',
                    style: TextStyle(fontSize: 11, color: palette.outline),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('开源许可'),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: '随手记 Sui',
                    applicationVersion: '版本 $kAppVersion',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('隐私说明'),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('隐私说明'),
                      content: const Text(
                        '随手记 Sui 是自托管笔记应用：数据默认只保存在本机与您自己的服务端；'
                        '不接入第三方分析或广告 SDK。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: const Text('复制版本信息'),
                  trailing: const Icon(Icons.copy, size: 18),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(
                      text: '随手记 Sui 版本 $kAppVersion '
                          '(${Theme.of(context).platform.name})',
                    ));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('版本信息已复制')),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            '© 2026 随手记 Sui',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: palette.outline),
          ),
        ],
      ),
    );
  }
}


/// MB-M03「归档」。
class MineArchivePage extends StatelessWidget {
  const MineArchivePage({
    super.key,
    required this.controller,
    this.onOpenNote,
  });

  final AppController controller;
  final Future<void> Function(String id)? onOpenNote;

  @override
  Widget build(BuildContext context) => _MineNotesPage(
        controller: controller,
        archived: true,
        onOpenNote: onOpenNote,
      );
}

/// MB-M04「回收站」：逐条还原；「清空回收站」本期置灰。
class MineTrashPage extends StatelessWidget {
  const MineTrashPage({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) =>
      _MineNotesPage(controller: controller, archived: false);
}

class _MineNotesPage extends StatefulWidget {
  const _MineNotesPage({
    required this.controller,
    required this.archived,
    this.onOpenNote,
  });

  final AppController controller;
  final bool archived;
  final Future<void> Function(String id)? onOpenNote;

  @override
  State<_MineNotesPage> createState() => _MineNotesPageState();
}

class _MineNotesPageState extends State<_MineNotesPage> {
  final TextEditingController _search = TextEditingController();
  List<NoteSummary>? _items;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = widget.archived
        ? await widget.controller.repository
            .listArchivedNotes(search: _search.text.trim())
        : await widget.controller.repository
            .listDeletedNotes(search: _search.text.trim());
    if (!mounted) return;
    setState(() => _items = list);
  }

  String _notebookName(String? id) {
    if (id == null) return '未分类';
    for (final n in widget.controller.notebooks) {
      if (n.id == id) return n.name;
    }
    return '未分类';
  }

  Future<void> _open(NoteSummary summary) async {
    Navigator.of(context).pop();
    final open = widget.onOpenNote;
    if (open != null) {
      await open(summary.note.id);
    } else {
      widget.controller.selectNote(summary.note.id);
    }
  }

  Future<void> _unarchive(NoteSummary summary) async {
    await widget.controller.repository.archiveNote(summary.note.id, false);
    await widget.controller.refreshNotes();
    if (mounted) await _load();
  }

  Future<void> _restore(NoteSummary summary) async {
    await widget.controller.restoreNote(summary.note.id);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return MinePanelScaffold(
      title: widget.archived ? '归档' : '回收站',
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: Text(
              items == null ? '' : '${items.length} 篇',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ),
      ],
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              onChanged: (_) => unawaited(_load()),
              decoration: InputDecoration(
                hintText: widget.archived ? '搜索归档笔记…' : '搜索回收站…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          if (!widget.archived)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '删除的笔记会保留，直到手动清空。',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ),
          Expanded(
            child: items == null
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                    ? Center(
                        child: Text(
                          widget.archived ? '暂无归档笔记' : '回收站为空',
                          style: TextStyle(color: theme.colorScheme.outline),
                        ),
                      )
                    : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final summary = items[index];
                          final note = summary.note;
                          return ListTile(
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            title: Text(
                              note.title.isEmpty ? '无标题' : note.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                              '${formatRelativeTime(note.updatedAt)} · '
                              '${_notebookName(note.notebookId)}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: theme.colorScheme.outline),
                            ),
                            onTap: widget.archived
                                ? () => unawaited(_open(summary))
                                : null,
                            trailing: TextButton(
                              onPressed: () => unawaited(widget.archived
                                  ? _unarchive(summary)
                                  : _restore(summary)),
                              child: Text(widget.archived ? '取消归档' : '还原'),
                            ),
                          );
                        },
                      ),
          ),
          if (!widget.archived)
            const SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: null,
                    child: Text('清空回收站'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
