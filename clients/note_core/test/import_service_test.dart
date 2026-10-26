import 'dart:convert';
import 'dart:typed_data';

import 'package:note_core/note_core.dart';
import 'package:test/test.dart';

/// 采集写入内容的假 BlobStore（M13 / §7：内容寻址 + 幂等）。
class _FakeBlobStore implements BlobStore {
  final Map<String, Uint8List> stored = {};
  bool failNextPut = false;

  @override
  Future<String> put({required String sha256, required Uint8List bytes}) async {
    if (failNextPut) {
      failNextPut = false;
      throw StateError('磁盘写失败（测试注入）');
    }
    stored[sha256] = bytes;
    return sha256;
  }

  @override
  Future<Uint8List?> read(String sha256) async => stored[sha256];

  @override
  Future<bool> exists(String sha256) async => stored.containsKey(sha256);

  @override
  Future<void> delete(String sha256) async => stored.remove(sha256);

  @override
  Future<void> dispose() async {}
}

/// M13 批量导入服务单测（详细设计 §13 测试矩阵）。
///
/// 覆盖：AC-236（限额 / 空 / 不支持类型）、AC-238（取消）、AC-240（加密目标）、
/// AC-245\~AC-249（资源本地化与降级）、AC-252（幂等去重）、AC-253 / AC-254（报告）、
/// AC-255（事务性）、AC-257（不进净荷）。
void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late _FakeBlobStore blobs;
  late FileImportService service;

  setUp(() {
    db = AppDatabase.memory();
    repo = NoteRepository(db, deviceId: 'test-device');
    blobs = _FakeBlobStore();
    service = FileImportService(repository: repo, blobStore: blobs);
  });

  tearDown(() => db.close());

  ImportSourceFile file(
    String name,
    String content, {
    Uint8List? bytes,
    ResourceResolver? resolver,
  }) =>
      ImportSourceFile(
        name: name,
        bytes: bytes ?? Uint8List.fromList(utf8.encode(content)),
        resolveResource: resolver,
      );

  Future<int> noteCount() async => (await repo.listNotes()).length;

  // -------------------------------------------------------------------------
  group('目标预检（BR-60.2 / AC-240）', () {
    test('未分组 → 可导入', () async {
      expect(await service.checkTarget(null), isNull);
    });

    test('存在的普通笔记本 → 可导入', () async {
      final nb = await repo.createNotebook(name: '工作');
      expect(await service.checkTarget(nb.id), isNull);
    });

    test('不存在的笔记本 → 拒绝', () async {
      expect(await service.checkTarget('不存在'), isNotNull);
    });

    test('已软删除的笔记本 → 拒绝', () async {
      final nb = await repo.createNotebook(name: '待删');
      await repo.removeNotebook(nb.id);
      expect(await service.checkTarget(nb.id), isNotNull);
    });

    test('加密且未解锁 → 拒绝，且**零写入**', () async {
      final created = await NotebookCrypto.create(password: 'pw');
      final nb = await repo.createNotebook(
        name: '私密',
        encrypted: true,
        cryptoMeta: created.meta.toJson(),
      );
      final reason = await service.checkTarget(nb.id);
      expect(reason, isNotNull);
      expect(reason, contains('解锁'));

      final report = await service.run([file('a.md', '# T\n正文')],
          notebookId: nb.id);
      expect(report.successCount, 0);
      expect(await noteCount(), 0, reason: 'AC-240：拒绝时不得写入');
    });

    test('加密且已解锁 → 可导入', () async {
      final created = await NotebookCrypto.create(password: 'pw');
      final nb = await repo.createNotebook(
        name: '私密',
        encrypted: true,
        cryptoMeta: created.meta.toJson(),
      );
      await repo.unlockNotebook(nb.id, 'pw');
      expect(await service.checkTarget(nb.id), isNull);
      final report =
          await service.run([file('a.md', '正文')], notebookId: nb.id);
      expect(report.successCount, 1);
      final notes = await repo.listNotes();
      expect(notes.single.note.title, 'a');
    });

    test('导入途中被回锁 → 该篇 failed，其余继续（AC-240）', () async {
      final created = await NotebookCrypto.create(password: 'pw');
      final nb = await repo.createNotebook(
        name: '私密',
        encrypted: true,
        cryptoMeta: created.meta.toJson(),
      );
      await repo.unlockNotebook(nb.id, 'pw');
      expect(await service.checkTarget(nb.id), isNull);
      // 模拟「途中自动回锁」：预检通过后立刻回锁。
      repo.lockNotebook(nb.id);
      final report = await service.run(
        [file('a.md', '一'), file('b.txt', '二')],
        notebookId: nb.id,
      );
      expect(report.failedCount, 2);
      expect(report.successCount, 0);
      expect(report.items.first.failureReason, contains('锁定'));
      expect(await noteCount(), 0);
    });
  });

  // -------------------------------------------------------------------------
  group('限额与空文件（BR-60.3 / BR-60.4 / AC-236）', () {
    test('不支持的扩展名 → skipped(unsupportedType)，不读字节', () async {
      final report = await service.run(
          [file('a.enex', '<en-export/>'), file('b.docx', 'x')],
          notebookId: null);
      expect(report.skippedCount, 2);
      expect(report.items.every((i) => i.skipReason == ImportSkipReason.unsupportedType),
          isTrue);
      expect(await noteCount(), 0);
    });

    test('扩展名大小写不敏感（.MD / .Html）', () async {
      final report = await service.run(
          [file('A.MD', '# 甲\n正文'), file('B.Html', '<p>乙</p>')],
          notebookId: null);
      expect(report.successCount, 2);
    });

    test('空文件 / 全空白 → skipped(empty)', () async {
      final report = await service.run(
          [file('a.txt', ''), file('b.txt', '   \n\n  \n'), file('c.html', '')],
          notebookId: null);
      expect(report.skippedCount, 3);
      expect(report.items.map((i) => i.skipReason),
          everyElement(ImportSkipReason.empty));
      expect(await noteCount(), 0);
    });

    test('超过单文件上限 → skipped(tooLarge)，不中断整批', () async {
      final small = FileImportService(
        repository: repo,
        blobStore: blobs,
        options: const ImportOptions(maxFileBytes: 8),
      );
      final report = await small.run(
          [file('a.txt', '123456789'), file('b.txt', 'ok')],
          notebookId: null);
      expect(report.items[0].skipReason, ImportSkipReason.tooLarge);
      expect(report.items[1].outcome, ImportOutcome.success);
    });

    test('超过单批文件数 → 超出者 skipped(batchLimit)（BR-60.3）', () async {
      final tiny = FileImportService(
        repository: repo,
        blobStore: blobs,
        options: const ImportOptions(maxFiles: 3),
      );
      final files = [for (var i = 0; i < 5; i++) file('f$i.txt', '内容 $i')];
      final report = await tiny.run(files, notebookId: null);
      expect(report.successCount, 3);
      expect(report.skippedCount, 2);
      expect(report.items.where((i) => i.skipReason == ImportSkipReason.batchLimit),
          hasLength(2));
    });
  });

  // -------------------------------------------------------------------------
  group('转换落库（FR-60 / FR-61）', () {
    test('md 保真落库；首行 H1 作标题', () async {
      const src = '# 我的标题\n\n正文\r\n第二行\n';
      final report = await service.run([file('忽略.md', src)], notebookId: null);
      expect(report.successCount, 1);
      final note = (await repo.listNotes()).single.note;
      expect(note.title, '我的标题');
      expect(note.contentMarkdown, src, reason: 'BR-61.1：逐字节保真');
      expect(note.revisionCount, 1, reason: 'BR-60.6：首条修订同事务写入');
      // 没有同步配置时不会「待上传」而是「仅本地」（与既有新建笔记同口径，BR-60.8）。
      expect(
        note.syncState,
        anyOf(EntitySyncState.pending, EntitySyncState.localOnly),
      );
    });

    test('txt 空白规整后落库，标题取文件名', () async {
      final report =
          await service.run([file('清单.txt', 'a\r\n\r\n\r\n\r\nb\r\n')], notebookId: null);
      expect(report.successCount, 1);
      final note = (await repo.listNotes()).single.note;
      expect(note.title, '清单');
      expect(note.contentMarkdown, 'a\n\nb\n');
    });

    test('html 无标题 → 回退文件名；多节 → 多篇笔记 + 逐条报告', () async {
      final report = await service.run([
        file('导出.html', '<html><body>'
            '<div class="html-note"><en-note><h1>第一篇</h1><p>1</p></en-note></div>'
            '<div class="html-note"><en-note><p>2</p></en-note></div>'
            '</body></html>'),
      ], notebookId: null);
      expect(report.successCount, 2, reason: 'BR-61.9：按笔记逐条报告');
      expect(report.items.map((i) => i.fileName), ['导出.html', '导出.html']);
      expect(report.items.map((i) => i.title), ['第一篇', '导出 (2)']);
      expect(await noteCount(), 2);
    });

    test('索引页 → skipped(indexPage)，不落库（BR-61.10）', () async {
      final report = await service.run(
          [file('Evernote_index.html', '<html><body><a href="a.html">a</a></body></html>')],
          notebookId: null);
      expect(report.skippedCount, 1);
      expect(report.items.single.skipReason, ImportSkipReason.indexPage);
      expect(await noteCount(), 0);
    });

    test('编码降级 → warning 呈现「编码可能不正确」（BR-61.7 / AC-251）', () async {
      final bad = Uint8List.fromList([
        ...utf8.encode('# T\n'),
        0xFF,
        0xFE,
      ]);
      final report = await service.run(
          [ImportSourceFile(name: '脏.md', bytes: bad)],
          notebookId: null);
      expect(report.successCount, 1);
      expect(report.items.single.warning, '编码可能不正确');
      expect(report.toClipboardText(), contains('编码可能不正确'));
    });
  });

  // -------------------------------------------------------------------------
  group('资源本地化（§7 / AC-245 / AC-246 / AC-248 / AC-249）', () {
    test('相对资源命中 → sui:// 引用 + 附件映射 + refcount', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final report = await service.run([
        file('a.html', '<p><img src="img/x.png" alt="图"></p>',
            resolver: (ref) async => ref == 'img/x.png' ? bytes : null),
      ], notebookId: null);
      expect(report.successCount, 1);
      expect(report.items.single.localizedResources, 1);
      expect(report.items.single.unlocalizedResources, 0);
      final sha = sha256Hex(bytes);
      final note = (await repo.listNotes()).single.note;
      expect(note.contentMarkdown, '![图](sui://$sha)\n');
      expect(blobs.stored.containsKey(sha), isTrue);
      final atts = await repo.listAttachments(noteId: note.id);
      expect(atts.single.filename, 'x.png');
      expect(atts.single.mimeKind, 'image');
      expect(atts.single.byteSize, 4);
    });

    test('resolver 返回 null → 降级为 alt 文本并计未本地化（AC-248）', () async {
      final report = await service.run([
        file('a.html', '<p><img src="missing.png" alt="图"></p>',
            resolver: (ref) async => null),
      ], notebookId: null);
      expect(report.successCount, 1);
      expect(report.items.single.unlocalizedResources, 1);
      expect((await repo.listNotes()).single.note.contentMarkdown, '图\n');
    });

    test('无 resolver（Web 端）→ 相对资源一律降级', () async {
      final report = await service.run(
          [file('a.html', '<p><img src="img/x.png" alt="图"></p>')],
          notebookId: null);
      expect(report.items.single.unlocalizedResources, 1);
      expect((await repo.listNotes()).single.note.contentMarkdown, '图\n');
    });

    test('resolver 抛异常 → 降级，不使整篇失败', () async {
      final report = await service.run([
        file('a.html', '<p><img src="boom.png" alt="图"></p>',
            resolver: (ref) async => throw StateError('读盘失败')),
      ], notebookId: null);
      expect(report.successCount, 1);
      expect(report.items.single.unlocalizedResources, 1);
    });

    test('data: 图片解码入库（AC-249）', () async {
      final report = await service.run([
        file('a.html',
            '<p><img src="data:image/png;base64,MTIz" alt="d"></p>'),
      ], notebookId: null);
      expect(report.items.single.localizedResources, 1);
      final note = (await repo.listNotes()).single.note;
      expect(note.contentMarkdown,
          '![d](sui://${sha256Hex(Uint8List.fromList([0x31, 0x32, 0x33]))})\n');
    });

    test('data: 解码失败 → 降级并计未本地化', () async {
      final report = await service.run([
        file('a.html', '<p><img src="data:image/png;base64,!!!!" alt="d"></p>'),
      ], notebookId: null);
      expect(report.items.single.unlocalizedResources, 1);
      expect((await repo.listNotes()).single.note.contentMarkdown, 'd\n');
    });

    test('远端图片保持 URL，且**不调用 resolver**（AC-247 / FR-61）', () async {
      var called = 0;
      final report = await service.run([
        file('a.html', '<p><img src="https://x.example/y.png" alt="远程"></p>',
            resolver: (ref) async {
              called++;
              return Uint8List.fromList([9]);
            }),
      ], notebookId: null);
      expect(called, 0, reason: '导入不出网、也不问平台层');
      expect(report.items.single.localizedResources, 0);
      expect(report.items.single.unlocalizedResources, 0);
      expect((await repo.listNotes()).single.note.contentMarkdown,
          '![远程](https://x.example/y.png)\n');
      expect(blobs.stored, isEmpty);
    });

    test('远端链接保持 URL', () async {
      await service.run([
        file('a.html', '<p><a href="https://x.example/a">站点</a></p>'),
      ], notebookId: null);
      expect((await repo.listNotes()).single.note.contentMarkdown,
          '[站点](https://x.example/a)\n');
    });

    test('本地链接命中 → 附件链接（link 降级保留文字）', () async {
      final report = await service.run([
        file('a.html', '<p><a href="files/doc.pdf">附件</a></p>',
            resolver: (ref) async => Uint8List.fromList([7, 7])),
      ], notebookId: null);
      expect(report.items.single.localizedResources, 1);
      final note = (await repo.listNotes()).single.note;
      final sha = sha256Hex(Uint8List.fromList([7, 7]));
      expect(note.contentMarkdown, '[附件](sui://$sha)\n');
      expect((await repo.listAttachments(noteId: note.id)).single.mimeKind, 'pdf');
    });

    test('本地链接缺失 → 仅保留链接文字', () async {
      final report = await service.run([
        file('a.html', '<p><a href="files/doc.pdf">附件</a></p>',
            resolver: (ref) async => null),
      ], notebookId: null);
      expect(report.items.single.unlocalizedResources, 1);
      expect((await repo.listNotes()).single.note.contentMarkdown, '附件\n');
    });

    test('超限资源 → 降级（BR-60.3）', () async {
      final small = FileImportService(
        repository: repo,
        blobStore: blobs,
        // 文件上限 64（HTML 本体要通过），但资源字节 128 超限 → 该资源降级。
        options: const ImportOptions(maxFileBytes: 64),
      );
      final report = await small.run([
        file('a.html', '<p><img src="big.png" alt="大"></p>',
            resolver: (ref) async => Uint8List.fromList(List.filled(128, 1))),
      ], notebookId: null);
      expect(report.successCount, 1);
      expect(report.items.single.unlocalizedResources, 1);
      expect((await repo.listNotes()).single.note.contentMarkdown, '大\n');
    });

    test('blobStore.put 抛异常 → 该资源降级，整篇仍成功（§7 第 2 条）', () async {
      blobs.failNextPut = true;
      final report = await service.run([
        file('a.html', '<p><img src="x.png" alt="图">文字</p>',
            resolver: (ref) async => Uint8List.fromList([1, 2])),
      ], notebookId: null);
      expect(report.successCount, 1);
      expect(report.items.single.unlocalizedResources, 1);
      expect((await repo.listNotes()).single.note.contentMarkdown, '图文字\n');
    });

    test('篇内同一资源引用两次 → 只建一条映射（BR-61.4）', () async {
      final bytes = Uint8List.fromList([5, 5, 5]);
      final report = await service.run([
        file('a.html', '<p><img src="x.png" alt="一"><img src="x.png" alt="二">'
            '</p>', resolver: (ref) async => bytes),
      ], notebookId: null);
      expect(report.items.single.localizedResources, 2);
      final note = (await repo.listNotes()).single.note;
      expect(await repo.listAttachments(noteId: note.id), hasLength(1),
          reason: '同一 sha256 只建一条附件映射，避免自增引用计数');
      final sha = sha256Hex(bytes);
      expect(note.contentMarkdown, '![一](sui://$sha)![二](sui://$sha)\n');
    });

    test('图片尺寸写入 {width=N}（BR-61.5 / AC-250）', () async {
      await service.run([
        file('a.html', '<p><img src="x.png" alt="图" width="320"></p>',
            resolver: (ref) async => Uint8List.fromList([1])),
      ], notebookId: null);
      final sha = sha256Hex(Uint8List.fromList([1]));
      expect((await repo.listNotes()).single.note.contentMarkdown,
          '![图](sui://$sha){width=320}\n');
    });

    test('链接包图片（本地文件）→ 只保留外层附件引用，**不产生嵌套引用**（`v0.13.2` 修复）',
        () async {
      // 真实形态（印象笔记导出，29 篇里 7 处）：`<a href="…文件.pdf"><img src="…缩略图.png" alt="…文件.pdf"></a>`
      // 客户端的附件引用识别是**扁平正则**（`editor_format.dart`），嵌套 `[![…](sui://图)](sui://文件)`
      // 会被它误读成「标签 = `![…`、sha = 内层图片」，剩下的 `](sui://文件)` 当字面量渲染
      // ——用户报的「附件显示错误」。故导入侧保证引用永不嵌套：外层附件胜出。
      final nb = await repo.createNotebook(name: 'nb');
      final html = '<html><head><title>嵌套</title></head><body>'
          '<div><a href="a files/doc.pdf"><img src="a files/i.png" alt="doc.pdf"></a></div>'
          '</body></html>';
      final report = await service.run([
        file('nested.html', html,
            resolver: (ref) async => ref.endsWith('doc.pdf')
                ? Uint8List.fromList([4, 5])
                : (ref.endsWith('i.png') ? Uint8List.fromList([1, 2, 3]) : null)),
      ], notebookId: nb.id);
      final item = report.items.single;
      expect(item.outcome, ImportOutcome.success);
      // `noteId` 非空（ImportItemResult 的默认值 `''`），落库态用 `!` 收窄可空返回。
      final md = (await repo.getStoredNote(item.noteId))!.contentMarkdown;
      // 单条**附件链接**引用（非图片目标 → `[…]`），标签取内层图片的 alt
      expect(md.contains('[doc.pdf](sui://'), isTrue);
      expect(md.contains('[!['), isFalse, reason: '不得产生嵌套引用');
      expect(md.contains('\u{E000}'), isFalse, reason: '不得残留占位符');
      expect(md.contains('\u{E001}'), isFalse);
      expect(item.localizedResources, 1);
      expect(item.unlocalizedResources, 0);
      // 只挂外层附件（PDF）；内层缩略图没有被引用 → 不落盘、不建映射
      expect(blobs.stored, hasLength(1));
      final atts = await repo.listAttachments(noteId: item.noteId);
      expect(atts.map((a) => a.filename).toList(), ['doc.pdf']);
    });

    test('链接包图片（远端链接）→ 保留原 URL，同样不嵌套', () async {
      final nb = await repo.createNotebook(name: 'nb');
      final html = '<html><head><title>嵌套远端</title></head><body>'
          '<div><a href="https://e.com/d.pdf"><img src="a files/i.png" alt="图标"></a></div>'
          '</body></html>';
      final report = await service.run([
        file('nested_remote.html', html,
            resolver: (ref) async => ref.endsWith('i.png')
                ? Uint8List.fromList([7, 8, 9])
                : null),
      ], notebookId: nb.id);
      final item = report.items.single;
      expect(item.outcome, ImportOutcome.success);
      final md = (await repo.getStoredNote(item.noteId))!.contentMarkdown;
      expect(md.contains('\u{E000}'), isFalse);
      expect(md.contains('[!['), isFalse, reason: '不得产生嵌套引用');
      // 远端链接保持 URL、不出网（AC-247）；标签取内层图片的 alt
      expect(md.contains('[图标](https://e.com/d.pdf)'), isTrue);
      expect(item.localizedResources, 0);
      expect(blobs.stored, isEmpty);
    });

    test('`<img>` 指向明确的非图片文件 → 按附件链接 `[name](sui://…)` 登记（不是 `![]`）',
        () async {
      final nb = await repo.createNotebook(name: 'nb');
      final html = '<html><head><title>非图片</title></head><body>'
          '<div><img src="a files/说明.pdf" alt="说明.pdf"></div>'
          '</body></html>';
      final report = await service.run([
        file('nonimage.html', html,
            resolver: (ref) async => Uint8List.fromList([1, 1, 1])),
      ], notebookId: nb.id);
      final item = report.items.single;
      final md = (await repo.getStoredNote(item.noteId))!.contentMarkdown;
      expect(md.contains('[说明.pdf](sui://'), isTrue);
      expect(md.contains('![说明.pdf]'), isFalse, reason: 'PDF 不该标成图片引用');
    });

    test('无扩展名的图片资源（导出常见 `interlace%2C1`）仍按图片引用 `![]`', () async {
      final nb = await repo.createNotebook(name: 'nb');
      final html = '<html><head><title>无扩展名</title></head><body>'
          '<div><img src="a files/interlace%2C1" alt="图"></div>'
          '</body></html>';
      final report = await service.run([
        file('noext.html', html,
            resolver: (ref) async => Uint8List.fromList([2, 2, 2])),
      ], notebookId: nb.id);
      final item = report.items.single;
      final md = (await repo.getStoredNote(item.noteId))!.contentMarkdown;
      expect(md.contains('![图](sui://'), isTrue);
    });

    test('降级时一律不残留占位符（§7 收尾）', () async {
      await service.run([
        file('a.html', '<p><img src="a.png" alt="A"><img src="b.png" alt="B">'
            '<a href="c.pdf">C</a></p>',
            resolver: (ref) async => ref == 'b.png' ? Uint8List.fromList([2]) : null),
      ], notebookId: null);
      final md = (await repo.listNotes()).single.note.contentMarkdown;
      expect(md.contains(kResourcePlaceholderStart), isFalse);
      expect(md.contains(kResourcePlaceholderEnd), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('幂等去重（FR-62 / BR-62.1 / BR-62.2 / AC-252）', () {
    test('同文件两次导入 → 第二次 duplicate，笔记数不变', () async {
      ImportSourceFile same() => file('a.md', '# 标题\n正文\n');
      final first = await service.run([same()], notebookId: null);
      expect(first.successCount, 1);
      final second = await service.run([same()], notebookId: null);
      expect(second.skippedCount, 1);
      expect(second.items.single.skipReason, ImportSkipReason.duplicate);
      expect(await noteCount(), 1);
    });

    test('**同批内**相同内容只导入第一篇（AC-252）', () async {
      // 文本链路的标题取自**文件名**，而指纹 = sha256(title + '\n' + markdown)，
      // 故「同内容不同文件名」本就该各导入一篇（BR-62.1 口径）。
      // 这里用**同名同内容**（如同一路径被选两次）验证同批去重。
      final report = await service.run(
          [file('a.txt', '同样内容'), file('a.txt', '同样内容')],
          notebookId: null);
      expect(report.successCount, 1);
      expect(report.skippedCount, 1);
      expect(report.items[1].skipReason, ImportSkipReason.duplicate);
      expect(await noteCount(), 1);
    });

    test('同内容不同文件名 → 各自导入（标题参与指纹，BR-62.1）', () async {
      final report = await service.run(
          [file('a.txt', '同样内容'), file('b.txt', '同样内容')],
          notebookId: null);
      expect(report.successCount, 2);
      expect(await noteCount(), 2);
    });

    test('内容不同即不同指纹', () async {
      final report = await service.run(
          [file('a.txt', '内容一'), file('b.txt', '内容二')],
          notebookId: null);
      expect(report.successCount, 2);
      expect(await noteCount(), 2);
    });

    test('指纹只记本地账：不进同步净荷（AC-257）', () async {
      await service.run([file('a.md', '# T\n正文')], notebookId: null);
      // 指纹只在本地库的 `notes.import_fingerprint` 列（纯本地记账，服务端无此字段）；
      // 领域模型 Note 也不暴露该列 → 不可能进入 push 净荷。
      expect(await repo.listImportFingerprints(), hasLength(1));
      final note = (await repo.listNotes()).single.note;
      expect(note.title, 'T');
      expect(note.contentMarkdown, '# T\n正文', reason: 'md 逐字节保真');
    });

    test('空串指纹的历史笔记不参与去重', () async {
      await repo.createNote(title: '老笔记', contentMarkdown: '内容一');
      expect(await repo.listImportFingerprints(), isEmpty);
      final report = await service.run([file('a.txt', '内容一')], notebookId: null);
      expect(report.successCount, 1, reason: '老数据指纹为 \'\' → 不误判为重复');
    });

    test('续跑幂等：取消后重跑同一批只补未导入的', () async {
      final files = [
        file('a.txt', '甲'),
        file('b.txt', '乙'),
        file('c.txt', '丙'),
      ];
      var seen = 0;
      final partial = await service.run(files,
          notebookId: null, isCancelled: () => ++seen > 2);
      expect(partial.cancelled, isTrue);
      expect(partial.successCount, 2);
      final again = await service.run(files, notebookId: null);
      expect(again.successCount, 1);
      expect(again.skippedCount, 2);
      expect(await noteCount(), 3);
    });
  });

  // -------------------------------------------------------------------------
  group('进度、取消与报告（§9 / AC-238 / AC-253 / AC-254）', () {
    test('进度按**文件**计（多节文件只计 1 次）', () async {
      final seen = <String>[];
      final report = await service.run([
        file('多节.html', '<div class="html-note"><p>1</p></div>'
            '<div class="html-note"><p>2</p></div>'),
        file('b.txt', '乙'),
      ], notebookId: null, onProgress: (p) => seen.add('${p.processed}/${p.total}'));
      expect(seen, ['1/2', '2/2']);
      expect(report.successCount, 3, reason: '多节产出 2 篇 + 1 篇');
    });

    test('取消在文件之间生效；已导入的保留（AC-238）', () async {
      final report = await service.run(
        [file('a.txt', '甲'), file('b.txt', '乙'), file('c.txt', '丙')],
        notebookId: null,
        isCancelled: () => false,
      );
      expect(report.cancelled, isFalse);
      expect(report.successCount, 3);

      var calls = 0;
      final cancelled = await service.run(
        [file('d.txt', '丁'), file('e.txt', '戊')],
        notebookId: null,
        isCancelled: () => ++calls > 1,
      );
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.successCount, 1);
      expect(cancelled.items, hasLength(1));
    });

    test('报告计数分列 + 跳过 / 失败原因可行动（AC-253）', () async {
      final report = await service.run([
        file('ok.md', '# 好\n正文'),
        file('dup.md', '# 好\n正文'),
        file('bad.enex', '<en-export/>'),
        file('empty.txt', ''),
        file('index.html', '<html><body>x</body></html>'),
      ], notebookId: null);
      expect(report.successCount, 1);
      expect(report.skippedCount, 4);
      expect(report.failedCount, 0);
      final text = report.toClipboardText();
      expect(text, contains('成功 1 · 跳过 4 · 失败 0'));
      expect(text, contains('[跳过·重复] dup.md'));
      expect(text, contains('[跳过·不支持的类型] bad.enex'));
      expect(text, contains('[跳过·空文件] empty.txt'));
      expect(text, contains('[跳过·索引页] index.html'));
      expect(text, contains('[成功] ok.md'));
    });

    test('失败项原因可行动（BR-62.3）', () async {
      // 附件插入失败（见「事务性」组）已在上面覆盖 failed 分支；
      // 这里覆盖「不支持扩展名 + 空文件」这类**可行动**跳过原因。
      final report = await service.run(
          [file('a.enex', 'x'), file('b.txt', '')],
          notebookId: null);
      expect(report.failedCount, 0);
      expect(report.items[0].skipReason, ImportSkipReason.unsupportedType);
      expect(report.items[1].skipReason, ImportSkipReason.empty);
      expect(report.toClipboardText(), contains('不支持的类型'));
      expect(report.toClipboardText(), contains('空文件'));
    });

    test('toClipboardText() 不含正文（BR-62.4 / AC-254）', () async {
      const secret = '这是笔记正文里的敏感内容';
      final report = await service.run([file('a.md', '# 标题\n$secret')],
          notebookId: null);
      final text = report.toClipboardText();
      expect(text, contains('标题'));
      expect(text, isNot(contains(secret)), reason: 'BR-62.4：报告不泄漏正文');
      expect(text, contains('随手记 Sui · 导入报告'));
    });

    test('报告抬头带目标笔记本名（未分组 → 「未分组」）', () async {
      final nb = await repo.createNotebook(name: '资料');
      final report =
          await service.run([file('a.txt', '甲')], notebookId: nb.id);
      expect(report.targetNotebookLabel, '资料');
      expect(report.toClipboardText(), contains('导入到：资料'));
      final ungrouped = await service.run([file('b.txt', '乙')], notebookId: null);
      expect(ungrouped.toClipboardText(), contains('导入到：未分组'));
    });
  });

  // -------------------------------------------------------------------------
  group('事务性（BR-60.6 / AC-255）', () {
    test('注入附件写入失败 → 无「有修订 / 有附件、无正文」的中间态', () async {
      // 事务内写 attachments 时触发器报错 → 整篇回滚。
      await db.customStatement(
        'CREATE TRIGGER m13_fail_attach BEFORE INSERT ON attachments '
        'BEGIN SELECT RAISE(ABORT, \'injected failure\'); END;',
      );
      final report = await service.run([
        file('a.html', '<p><img src="x.png" alt="图">文字</p>',
            resolver: (ref) async => Uint8List.fromList([1, 2, 3])),
      ], notebookId: null);
      expect(report.failedCount, 1);
      expect(report.items.single.failureReason, contains('写入本地库失败'));
      expect(await noteCount(), 0, reason: 'AC-255：不得留下半篇笔记');
      final revisions = await db.select(db.revisions).get();
      expect(revisions, isEmpty, reason: '不得留下无正文的修订');
      final attachments = await db.select(db.attachments).get();
      expect(attachments, isEmpty, reason: '不得留下无归属的附件映射');
      // 孤儿 blob 由既有 GC / LRU 回收，不影响正确性（§3.4）。
      expect(await repo.listImportFingerprints(), isEmpty,
          reason: '失败不留指纹，重试可再次导入');
    });

    test('失败项不中断整批', () async {
      await db.customStatement(
        'CREATE TRIGGER m13_fail_attach2 BEFORE INSERT ON attachments '
        'BEGIN SELECT RAISE(ABORT, \'injected failure\'); END;',
      );
      final report = await service.run([
        file('a.html', '<p><img src="x.png" alt="图">A</p>',
            resolver: (ref) async => Uint8List.fromList([1])),
        file('b.txt', 'B'),
      ], notebookId: null);
      expect(report.failedCount, 1);
      expect(report.successCount, 1);
      expect(await noteCount(), 1);
    });
  });
}
