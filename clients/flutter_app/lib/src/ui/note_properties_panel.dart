import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import '../platform/url_opener.dart';
import 'app_controller.dart';
import 'time_format.dart';

/// 笔记属性面板（M15 / FR-74 / ui-spec §26.2）——**只读**属性清单。
///
/// 口径要点（逐条对应验收）：
/// * **只读**（BR-74.1）：面板内没有任何输入 / 保存 / 就地改写入口；值可复制（行尾复制按钮 +
///   整块 `SelectionArea` 可选中），复制**不改正本**；
/// * **取数不受筛选影响**（BR-74.3）：优先走 [AppController.noteById] 与
///   [AppController.tagsById]（按 id 直取）；中栏处于筛选态、该笔记不在当前列表范围内时，
///   再按 id 直取一次（`NoteRepository.getNoteSummary`）兜底，故中栏一筛选面板**不会空**；
/// * **加密未解锁**（BR-74.4 / BR-51）：不展示任何正文派生量（字数 / 字符数），
///   该行给遮罩文案而非数字，其余非内容元数据照常展示；
/// * **非剪藏笔记**：来源链接**整行不渲染**（不给占位符）；
/// * **空态**：目标笔记不存在（已删除 / 尚未同步到本机）→ 空态文案，不崩溃、不阻塞编辑；
/// * **随 noteId 重载**：`didUpdateWidget` 按 [noteId] 变化重载（同 `RevisionPanel` 范式）。
///
/// 面板**不写正本、不写库、不进同步**：`source_url` 是服务端只下行镜像，就地编辑必被
/// 下一次 `pull` 覆盖，故本组件刻意不提供编辑接缝。
class NotePropertiesPanel extends StatefulWidget {
  const NotePropertiesPanel({super.key, required this.noteId, this.debugNow});

  /// 呈现哪一篇笔记的属性。
  final String noteId;

  /// 「现在」的**测试注入点**：仅用于让相对时间断言确定（生产恒为 [DateTime.now]）。
  final DateTime Function()? debugNow;

  @override
  State<NotePropertiesPanel> createState() => _NotePropertiesPanelState();
}

class _NotePropertiesPanelState extends State<NotePropertiesPanel> {
  /// 中栏筛选态下的**按 id 直取**兜底摘要（BR-74.3）。
  NoteSummary? _fallback;

  /// 兜底取数尚未返回（仅用于空态文案区分「加载中」与「真的不存在」）。
  bool _loadingFallback = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFallbackIfNeeded());
  }

  @override
  void didUpdateWidget(covariant NotePropertiesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 面板随 noteId 变化**自动重载**（FR-74）：清掉上一篇的兜底摘要再按需重取。
    if (oldWidget.noteId != widget.noteId) {
      _fallback = null;
      _loadingFallback = false;
      unawaited(_loadFallbackIfNeeded());
    }
  }

  /// 中栏筛选态下 `noteById` 取不到时，按 id 直取一次（BR-74.3）。
  ///
  /// 直取失败（笔记确不存在 / 库异常）不抛给 UI：保持空态即可，属性面板**不阻塞编辑**。
  Future<void> _loadFallbackIfNeeded() async {
    final controller = context.read<AppController>();
    // 已在当前中栏列表（或独立窗口缓存）里 → 无需任何额外取数。
    if (controller.noteById(widget.noteId) != null) return;
    final id = widget.noteId;
    _loadingFallback = true;
    NoteSummary? summary;
    try {
      summary = await controller.repository.getNoteSummary(id);
    } catch (error) {
      debugPrint('[NotePropertiesPanel] 属性取数失败：$id → $error');
    }
    if (!mounted || widget.noteId != id) return;
    setState(() {
      _fallback = summary;
      _loadingFallback = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    // 按 id 直取（AC-125 / BR-74.3）：**不得**用受中栏筛选影响的 `selectedNoteSummary`。
    final live = controller.noteById(widget.noteId);
    final note = live ?? _fallback?.note;
    if (note == null) {
      return _EmptyState(
        key: const ValueKey('sui-note-properties-empty'),
        loading: _loadingFallback,
      );
    }
    final tags = live != null
        ? controller.tagsById(widget.noteId)
        : (_fallback?.tags ?? const <String>[]);
    final theme = Theme.of(context);
    final now = (widget.debugNow ?? DateTime.now)();
    final notebookId = note.notebookId;
    final path = controller.notebookPathOf(notebookId);
    final notebookText = notebookId == null
        ? '未分组'
        : (path.isEmpty ? '（未知笔记本）' : path.join(' / '));
    // 正文派生量：加密未解锁时**一律不计算、不展示**（BR-74.4）。
    final stats = note.locked ? null : _textStats(note.contentMarkdown);

    return Container(
      key: const ValueKey('sui-note-properties-panel'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(theme),
          const Divider(height: 1),
          Expanded(
            child: SelectionArea(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  _PropertyRow(
                    label: '标题',
                    valueKey: 'sui-props-title',
                    value: note.title.trim().isEmpty ? '（无标题）' : note.title,
                    onCopy: () => _copy('标题', note.title),
                  ),
                  _PropertyRow(
                    label: '所属笔记本',
                    valueKey: 'sui-props-notebook',
                    value: notebookText,
                    onCopy: () => _copy('所属笔记本', notebookText),
                  ),
                  _PropertyRow(
                    label: '创建时间',
                    valueKey: 'sui-props-created',
                    value: _dualTime(note.createdAt, now),
                    tooltip: formatLocalDateTime(note.createdAt, withSeconds: true),
                    onCopy: () => _copy('创建时间',
                        formatLocalDateTime(note.createdAt, withSeconds: true)),
                  ),
                  _PropertyRow(
                    label: '上次修改时间',
                    valueKey: 'sui-props-updated',
                    value: _dualTime(note.updatedAt, now),
                    tooltip: formatLocalDateTime(note.updatedAt, withSeconds: true),
                    onCopy: () => _copy('上次修改时间',
                        formatLocalDateTime(note.updatedAt, withSeconds: true)),
                  ),
                  // 来源链接：**非剪藏笔记整行不渲染**（不给占位符）。
                  if (note.sourceUrl.trim().isNotEmpty)
                    _PropertyRow(
                      label: '来源链接',
                      valueKey: 'sui-props-source-url',
                      value: note.sourceUrl,
                      isLink: isOpenableUrl(note.sourceUrl),
                      onTap: isOpenableUrl(note.sourceUrl)
                          ? () => _openSourceUrl(note.sourceUrl)
                          : null,
                      onCopy: () => _copy('来源链接', note.sourceUrl),
                    ),
                  _PropertyRow(
                    label: '标签',
                    valueKey: 'sui-props-tags',
                    value: tags.isEmpty ? '无标签' : tags.join('、'),
                    onCopy: () => _copy('标签', tags.join('、')),
                  ),
                  _PropertyRow(
                    label: '修订次数',
                    valueKey: 'sui-props-revisions',
                    value: '${note.revisionCount}',
                    onCopy: () => _copy('修订次数', '${note.revisionCount}'),
                  ),
                  _PropertyRow(
                    label: '版本号',
                    valueKey: 'sui-props-version',
                    value: note.version == 0 ? '0（本地新建，尚未上行）' : 'v${note.version}',
                    onCopy: () => _copy('版本号', '${note.version}'),
                  ),
                  _PropertyRow(
                    label: '来源设备',
                    valueKey: 'sui-props-device',
                    value: note.sourceDevice.trim().isEmpty ? '未知' : note.sourceDevice,
                    onCopy: () => _copy('来源设备', note.sourceDevice),
                  ),
                  _PropertyRow(
                    label: '同步状态',
                    valueKey: 'sui-props-sync',
                    value: note.syncError.isEmpty
                        ? note.syncState.label
                        : '${note.syncState.label}（${note.syncError}）',
                    onCopy: () => _copy('同步状态', note.syncState.label),
                  ),
                  // 字数 / 字符数：加密未解锁 → 遮罩文案，**不给数字**（BR-74.4）。
                  if (stats != null)
                    _PropertyRow(
                      label: '字数 / 字符数',
                      valueKey: 'sui-props-stats',
                      value: '${stats.words} 字 · ${stats.chars} 字符',
                      onCopy: () => _copy('字数 / 字符数',
                          '${stats.words} 字 · ${stats.chars} 字符'),
                    )
                  else
                    const _PropertyRow(
                      label: '字数 / 字符数',
                      valueKey: 'sui-props-stats-locked',
                      value: '内容已加密，解锁后可见',
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 标题栏：面板名 + **只读**标识（BR-74.1 的可见承诺：面板内无编辑入口）。
  Widget _header(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text('属性', style: theme.textTheme.titleSmall),
          const Spacer(),
          Container(
            key: const ValueKey('sui-note-properties-readonly'),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('只读', style: theme.textTheme.labelSmall),
          ),
        ],
      ),
    );
  }

  /// 时间**双格式**：本地时间与相对时间同处一行（ui-spec §26.2）。
  String _dualTime(DateTime dt, DateTime now) =>
      '${formatLocalDateTime(dt)}（${formatRelativeTime(dt, now: now)}）';

  /// 复制某字段值（**只复制，不改正本**）。
  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已复制$label')));
  }

  /// 用**系统默认浏览器**打开来源链接：协议白名单与失败提示同 FR-70 / BR-70.2 / BR-70.4。
  ///
  /// 本面板**只读**：打开失败 / 非白名单一律只提示，绝不写回正本。
  Future<void> _openSourceUrl(String url) async {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!isOpenableUrl(url)) {
      messenger.showSnackBar(SnackBar(content: Text('不支持的链接协议：$url')));
      return;
    }
    final ok = await openExternalUrl(url);
    if (!ok) {
      messenger.showSnackBar(SnackBar(content: Text('未能打开链接：$url')));
    }
  }
}

/// 正文字数 / 字符数（FR-74「字数 / 字符数」）。
///
/// * `chars` = 正本 UTF-16 码元数（`String.length`，与编辑器偏移口径一致）；
/// * `words` = **去空白**后的字符数（中文按字计、西文按字符计，与常见笔记应用口径一致）。
({int words, int chars}) _textStats(String content) => (
      words: content.replaceAll(RegExp(r'\s'), '').length,
      chars: content.length,
    );

/// 一行只读属性：标签 + 值（+ 可选复制 / 打开）+ 可选悬停提示。
class _PropertyRow extends StatelessWidget {
  const _PropertyRow({
    required this.label,
    required this.value,
    required this.valueKey,
    this.tooltip,
    this.onTap,
    this.onCopy,
    this.isLink = false,
  });

  final String label;
  final String value;
  final String valueKey;
  final String? tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onCopy;

  /// 值是否按**链接**呈现（仅来源链接且协议在白名单内为真）。
  final bool isLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget valueWidget = Text(
      value,
      key: ValueKey(valueKey),
      style: isLink
          ? theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
              decoration: TextDecoration.underline,
            )
          : theme.textTheme.bodyMedium,
    );
    if (onTap != null) {
      valueWidget = InkWell(
        onTap: onTap,
        child: Tooltip(
          message: '在系统默认浏览器打开',
          child: valueWidget,
        ),
      );
    } else if (tooltip != null) {
      valueWidget = Tooltip(message: tooltip!, child: valueWidget);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: valueWidget),
          // 值**可复制**（不改正本）：行尾固定入口，避免依赖文本选择手势。
          if (onCopy != null)
            IconButton(
              key: ValueKey('$valueKey-copy'),
              tooltip: '复制$label',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy),
              onPressed: onCopy,
            )
          else
            const SizedBox(width: 32),
        ],
      ),
    );
  }
}

/// 空态（FR-74「空态」）：目标笔记不存在（已被删除 / 尚未同步到本机）。
class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      key: const ValueKey('sui-note-properties-empty-state'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.help_outline, size: 32, color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text('笔记不存在或尚未同步到本机', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              loading
                  ? '正在按笔记 ID 直接读取……'
                  : '该笔记可能已被删除，或尚未从服务端同步到本机；这不会影响编辑区。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
