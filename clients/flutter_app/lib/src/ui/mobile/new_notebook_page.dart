import 'package:flutter/material.dart';
import 'package:note_core/note_core.dart';

import '../app_controller.dart';
import '../appearance/app_palette.dart';

/// 笔记本路径：`工作 / 产品设计`；`null` = 顶层（M19 / FR-114）。
String notebookPathLabel(AppController controller, String? id) {
  if (id == null) return '顶层';
  final byId = <String, Notebook>{for (final n in controller.notebooks) n.id: n};
  final parts = <String>[];
  Notebook? cur = byId[id];
  var guard = 0;
  while (cur != null && guard++ < 64) {
    parts.insert(0, cur.name);
    cur = cur.parentId == null ? null : byId[cur.parentId];
  }
  return parts.isEmpty ? '顶层' : parts.join(' / ');
}

/// 移动端「新建笔记本」全屏表单（M19 / FR-114 / ui-spec §31.4）。
///
/// 只有名称与父级两项；创建成功后以 [Notebook] 出栈，由壳层入树高亮并弹 Snackbar。
class MobileNewNotebookPage extends StatefulWidget {
  const MobileNewNotebookPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<MobileNewNotebookPage> createState() => _MobileNewNotebookPageState();
}

class _MobileNewNotebookPageState extends State<MobileNewNotebookPage> {
  final TextEditingController _name = TextEditingController();
  String? _parentId;
  bool _creating = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickParent() async {
    final result = await Navigator.of(context).push<_ParentChoice>(
      MaterialPageRoute(
        builder: (_) => _MobileParentPickerPage(
          controller: widget.controller,
          selectedId: _parentId,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _parentId = result.parentId);
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final notebook = await widget.controller
          .createNotebook(name, parentId: _parentId);
      if (!mounted) return;
      Navigator.of(context).pop(notebook);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _error = '创建失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    final canCreate = _name.text.trim().isNotEmpty && !_creating;
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('新建笔记本'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                children: [
                  Text('名称', style: _labelStyle(palette)),
                  const SizedBox(height: 6),
                  TextField(
                    key: const ValueKey('mobile-new-notebook-name'),
                    controller: _name,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _create(),
                    decoration: const InputDecoration(
                      hintText: '例如：工作',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('归属 / 父级', style: _labelStyle(palette)),
                  const SizedBox(height: 6),
                  InkWell(
                    key: const ValueKey('mobile-new-notebook-parent'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: _pickParent,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                      decoration: BoxDecoration(
                        color: palette.containerLow,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: palette.divider),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.folder_outlined,
                              size: 20, color: palette.outline),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _parentId == null
                                  ? '顶层 · 不放入任何笔记本'
                                  : '父级 · ${notebookPathLabel(widget.controller, _parentId)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15),
                            ),
                          ),
                          Icon(Icons.chevron_right, color: palette.outline),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '加密、移动、新建子笔记本均在创建后从笔记本菜单进入。',
                    style: TextStyle(fontSize: 12, color: palette.outline),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: 48,
                  child: FilledButton(
                    key: const ValueKey('mobile-new-notebook-create'),
                    onPressed: canCreate ? _create : null,
                    child: Text(_creating ? '创建中…' : '创建'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _labelStyle(AppPalette palette) => TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: palette.outline,
      );
}

/// 选择父级的返回值：`parentId == null` 表示顶层；`null` 结果表示取消。
class _ParentChoice {
  const _ParentChoice(this.parentId);
  final String? parentId;
}

/// 选择父级（M19 / FR-114）：顶层 + 笔记本树；加密笔记本显示锁且**禁选**。
class _MobileParentPickerPage extends StatefulWidget {
  const _MobileParentPickerPage({
    required this.controller,
    required this.selectedId,
  });

  final AppController controller;
  final String? selectedId;

  @override
  State<_MobileParentPickerPage> createState() =>
      _MobileParentPickerPageState();
}

class _MobileParentPickerPageState extends State<_MobileParentPickerPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final palette = SuiAppearance.of(context).palette;
    final rows = _flatten(widget.controller);
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? rows
        : rows.where((r) => r.$1.name.toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('选择父级'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                key: const ValueKey('mobile-parent-search'),
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索笔记本',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: palette.containerLow,
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    key: const ValueKey('mobile-parent-top'),
                    leading: const Icon(Icons.layers_outlined),
                    title: const Text('顶层'),
                    subtitle: const Text('不放入任何笔记本'),
                    trailing: widget.selectedId == null
                        ? const Icon(Icons.check_circle)
                        : const Icon(Icons.circle_outlined),
                    onTap: () => Navigator.of(context)
                        .pop<_ParentChoice>(const _ParentChoice(null)),
                  ),
                  const Divider(height: 1),
                  for (final row in shown)
                    _parentRow(context, row.$1, row.$2),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _parentRow(BuildContext context, Notebook nb, int depth) {
    final palette = SuiAppearance.of(context).palette;
    final selected = widget.selectedId == nb.id;
    final disabled = nb.encrypted;
    return ListTile(
      key: ValueKey('mobile-parent-${nb.id}'),
      enabled: !disabled,
      contentPadding: EdgeInsets.only(left: 16.0 + depth * 20, right: 16),
      leading: Icon(
        disabled ? Icons.lock_outline : Icons.folder_outlined,
        size: 20,
        color: disabled ? palette.outline : null,
      ),
      title: Text(nb.name),
      subtitle: disabled ? const Text('加密笔记本不能作为父级') : null,
      trailing: selected
          ? const Icon(Icons.check_circle)
          : const Icon(Icons.circle_outlined),
      onTap: disabled
          ? null
          : () => Navigator.of(context)
              .pop<_ParentChoice>(_ParentChoice(nb.id)),
    );
  }

  /// 树形展平：`(notebook, depth)`，按 `sortOrder` 同级排序。
  List<(Notebook, int)> _flatten(AppController controller) {
    final byParent = <String?, List<Notebook>>{};
    for (final nb in controller.notebooks) {
      byParent.putIfAbsent(nb.parentId, () => []).add(nb);
    }
    final rows = <(Notebook, int)>[];
    void walk(String? parentId, int depth) {
      final children = byParent[parentId] ?? const <Notebook>[];
      for (final nb in children) {
        rows.add((nb, depth));
        walk(nb.id, depth + 1);
      }
    }

    walk(null, 0);
    return rows;
  }
}
