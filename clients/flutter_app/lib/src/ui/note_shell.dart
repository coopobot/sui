import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_controller.dart';
import 'note_editor.dart';
import 'note_list.dart';
import 'notebook_tree.dart';

/// 应用主界面外壳：响应式三栏（笔记本树 / 笔记列表 / 编辑区）。
/// 宽屏（桌面/平板）三栏并排；窄屏（手机）用抽屉 + 导航堆栈。
class NoteShell extends StatelessWidget {
  const NoteShell({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final controller = context.watch<AppController>();

        if (wide) {
          return _WideLayout(controller: controller);
        }
        return _NarrowLayout(controller: controller);
      },
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('随手记 Sui'),
        actions: [_newNoteAction(context)],
      ),
      body: Row(
        children: [
          SizedBox(width: 280, child: NotebookTree(controller: controller)),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 2,
            child: NoteList(controller: controller),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 4,
            child: NoteEditor(key: ValueKey(controller.selectedNoteId)),
          ),
        ],
      ),
    );
  }

  Widget _newNoteAction(BuildContext context) {
    return IconButton(
      tooltip: '新建笔记',
      icon: const Icon(Icons.note_add_outlined),
      onPressed: () => controller.createNote(),
    );
  }
}

class _NarrowLayout extends StatelessWidget {
  const _NarrowLayout({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final editorOpen = controller.selectedNoteId != null;
    // 手机：选中笔记后进入全屏编辑页；平板中等宽度时可用双栏。
    return Scaffold(
      appBar: AppBar(
        title: Text(editorOpen ? '笔记' : '随手记 Sui'),
        leading: editorOpen
            ? BackButton(
                onPressed: () => controller.selectNote(null),
              )
            : null,
        actions: [
          if (editorOpen)
            IconButton(
              tooltip: '删除笔记',
              icon: const Icon(Icons.delete_outline),
              onPressed: () =>
                  controller.deleteNote(controller.selectedNoteId!),
            )
          else
            IconButton(
              tooltip: '新建笔记',
              icon: const Icon(Icons.note_add_outlined),
              onPressed: () => controller.createNote(),
            ),
        ],
      ),
      drawer: editorOpen ? null : NoteTreeDrawer(controller: controller),
      body: editorOpen
          ? NoteEditor(key: ValueKey(controller.selectedNoteId))
          : NoteList(controller: controller),
    );
  }
}