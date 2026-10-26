/// M8 附件列表跨窗口隔离回归测试（详细设计 [`multi-window.md`] §5.2）。
///
/// **背景**：`AppController._attachments` 是**单一共享字段**。M8 前 `note_editor.dart`
/// 在刷新后回读 `_controller.attachments` 来填本地 `_attachments`；单窗口下无害，
/// 但多窗口下两个编辑器可能**并发**刷新**不同**笔记——共享字段被「后到者」覆盖，
/// 先到者的列表被串扰成对方笔记的附件。
///
/// **修复**：`refreshAttachments` / `removeAttachment` **返回**该笔记的列表，调用方
/// 以返回值为准，绝不回读共享字段。
///
/// 本测试直接驱动这两个返回契约（无需真实窗口；共享字段仍会按「最后刷新者」更新，
/// 正是问题根源，故断言可以清晰证伪「回读」式实现）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';

/// 构建已 `bootstrap()` 的控制器（内存库，无需真实窗口）。
Future<AppController> _buildController() async {
  final db = AppDatabase.memory();
  final controller = AppController(
    repository: NoteRepository(db, deviceId: 'm8-attach-test'),
    database: db,
  );
  addTearDown(controller.dispose);
  await controller.bootstrap();
  return controller;
}

/// 直接经仓储挂一个附件（绕过 BlobStore，仅建元数据行）。
Future<Attachment> _attach(AppController c, String noteId, String name) {
  return c.repository.addAttachment(
    noteId: noteId,
    filename: name,
    mimeKind: 'file',
    sha256: 'sha-$name',
  );
}

void main() {
  group('M8 附件列表跨窗口隔离（§5.2）', () {
    test('两台「窗口」刷新不同笔记 → 各返回值只含各自笔记的附件', () async {
      final c = await _buildController();

      await c.createNote(title: 'A');
      final noteA = c.selectedNoteId!;
      await c.createNote(title: 'B');
      final noteB = c.selectedNoteId!;

      final attA = await _attach(c, noteA, 'a.txt');
      final attB = await _attach(c, noteB, 'b.txt');

      // 窗口 A 刷新笔记 A，窗口 B 刷新笔记 B（模拟并发，后到者覆盖共享字段）。
      final forA = await c.refreshAttachments(noteA);
      final forB = await c.refreshAttachments(noteB);

      // 返回契约：各窗口拿到的是**自己笔记**的列表。
      expect(forA.map((a) => a.id), [attA.id]);
      expect(forB.map((a) => a.id), [attB.id]);

      // 共享字段已被「后到者」B 覆盖——这正是回读式实现会串扰的根源。
      expect(c.attachments.map((a) => a.id), [attB.id]);

      // 关键回归：窗口 A 持有的 forA 未被 B 的刷新污染（≠ 共享字段）。
      expect(forA.map((a) => a.id), isNot(c.attachments.map((a) => a.id)));
    });

    test('刷新 A → 刷新 B → A 的列表仍是 A（顺序交错不串扰）', () async {
      final c = await _buildController();

      await c.createNote(title: 'A');
      final noteA = c.selectedNoteId!;
      await c.createNote(title: 'B');
      final noteB = c.selectedNoteId!;

      final attA = await _attach(c, noteA, 'a.txt');
      await _attach(c, noteB, 'b.txt');

      final forA = await c.refreshAttachments(noteA);
      await c.refreshAttachments(noteB);
      await c.refreshAttachments(noteA);

      // 窗口 A 始终以自己那次刷新的返回值为准（不受 B 干扰）。
      expect(forA.map((a) => a.id), [attA.id]);
    });

    test('removeAttachment 返回该笔记刷新后的列表，且不影响对方', () async {
      final c = await _buildController();

      await c.createNote(title: 'A');
      final noteA = c.selectedNoteId!;
      await c.createNote(title: 'B');
      final noteB = c.selectedNoteId!;

      final attA = await _attach(c, noteA, 'a.txt');
      final attB = await _attach(c, noteB, 'b.txt');

      final afterRemove = await c.removeAttachment(attA);

      // 返回值仅为「A 摘除后」的列表（空），不含 B 的附件。
      expect(afterRemove, isNotNull);
      expect(afterRemove!.map((a) => a.id), isEmpty);

      // B 未被牵连。
      final forB = await c.refreshAttachments(noteB);
      expect(forB.map((a) => a.id), [attB.id]);
    });

    test('空笔记刷新返回空列表（无附件不误报）', () async {
      final c = await _buildController();

      await c.createNote(title: '空');
      final noteId = c.selectedNoteId!;

      final list = await c.refreshAttachments(noteId);
      expect(list, isEmpty);
    });
  });
}
