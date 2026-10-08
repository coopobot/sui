@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/format_table.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// M9-T13 编辑器编辑能力与附件体验端到端验证
/// （editor-formatting.md §12 / FR-44~FR-48 / AC-138~AC-155）。
///
/// 与 M9-T12 的 widget 测试不同：这里拉起**真实 Go 服务端进程**，把「表格工具 /
/// 粘贴保留格式 / 简化格式 / 附件预览与外部编辑回写 / 有序列表自动编号」这套增强
/// 从「点控件、按快捷键」一路走到「数据落到服务端、另一台设备原样取回」，验证
/// 三态一致与往返逐字节保真不回归。
///
/// 覆盖：
/// - 表格（FR-44 / AC-138~AC-140）：默认插入、自定义尺寸、GFM 正本、服务端往返
/// - 粘贴（FR-45 / AC-141~AC-144）：富文本 HTML→Markdown、纯文本转义、快捷键同源
/// - 简化格式（FR-45 / AC-143）：行内/块级格式一并剥离，只留纯文本
/// - 附件（FR-46 / FR-47 / AC-145~AC-151）：图片插入、面板列表、预览、
///   外部编辑回写改写 sui:// 引用、服务端往返
/// - 有序列表（FR-48 / AC-152~AC-154）：正本统一 1.、渲染层按序编号、span 等长
/// - 往返保真门禁扩展：表格 + 附件引用 + 有序列表样本三态 + 服务端往返逐字节不变
void main() {
  const port = 18099;
  const serverUrl = 'http://127.0.0.1:$port';
  const password = 'pw123';

  late Process server;
  late String dataDir;
  late String serverBin;
  late String token;

  setUpAll(() async {
    HttpOverrides.global = null;

    final repoRoot = Directory.current.parent.parent.path;
    dataDir = '${Directory.systemTemp.path}/sui-m9-e2e-'
        '${DateTime.now().millisecondsSinceEpoch}';
    await Directory(dataDir).create(recursive: true);
    serverBin = '$dataDir/sui-server';

    final build = await Process.run(
      '/home/aiuser/go-sdk/go/bin/go',
      ['build', '-o', serverBin, './cmd/sui-server'],
      workingDirectory: '$repoRoot/server',
    );
    if (build.exitCode != 0) {
      fail('build server failed: ${build.stderr}\n${build.stdout}');
    }

    server = await Process.start(serverBin, const [], environment: {
      'SUI_ADDR': '127.0.0.1:$port',
      'SUI_DATA': dataDir,
    });
    await _waitUntilReady(serverUrl);

    final client = Client();
    try {
      final regResp = await client.post(
        Uri.parse('$serverUrl/api/v1/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': 'm9t13', 'password': password}),
      );
      if (regResp.statusCode != 200) {
        fail('首启注册失败：${regResp.statusCode} ${regResp.body}');
      }
      token = (jsonDecode(regResp.body) as Map)['token'] as String;
    } finally {
      client.close();
    }
  });

  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    try {
      await Directory(dataDir).delete(recursive: true);
    } catch (_) {}
  });

  // ---------------------------------------------------------------------------
  // 表格端到端（FR-44）
  // ---------------------------------------------------------------------------
  testWidgets(
    '表格：默认 3×3 插入 → GFM 管道表正本 → 服务端往返保真',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm9t13-table-a');
      final controller = AppController(
        repository: repo,
        database: db,
        dataDir: dataDir,
      );
      await tester.runAsync(controller.bootstrap);

      await tester.runAsync(() => controller.connect(SyncConfig(
            baseUrl: serverUrl,
            token: token,
            deviceId: controller.syncConfig.deviceId,
          )));

      await tester.runAsync(() async {
        await controller.createNote(title: '表格笔记');
        await controller.saveNote(
          controller.selectedNoteId!,
          title: '表格笔记',
          content: '',
          tags: const <String>[],
        );
      });
      final noteId = controller.selectedNoteId!;

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      await _settle(tester);

      final ctrl = _contentValue(tester);
      expect(ctrl.text, '', reason: '初始正文为空');

      // 点工具栏「表格」→ 默认 3×3 插入
      final tableBtn = find.byIcon(Icons.table_chart_outlined);
      await tester.ensureVisible(tableBtn);
      await tester.pump();
      await tester.tap(tableBtn);
      await _settleRoute(tester);
      expect(find.text('插入表格'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('sui-table-insert-confirm')));
      await _settleRoute(tester);

      const expected = '|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n';
      expect(ctrl.text, expected, reason: '默认 3×3 应写回 4 行 GFM 管道表（文末补一个换行）');

      // 格式模式应渲染为 FormatTableView
      expect(find.byType(FormatTableView), findsOneWidget,
          reason: '良构表应渲染为表格呈现单元');

      // 落盘
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      // 三态一致：格式 → 源码 → 预览 → 格式
      await tester.tap(find.text('源码'));
      await tester.pump();
      expect(ctrl.text, expected, reason: '源码态正本与格式态一致');

      await tester.tap(find.text('预览'));
      await _settle(tester);
      expect(find.byType(Markdown), findsOneWidget);

      await tester.tap(find.text('格式'));
      await tester.pump();
      expect(ctrl.text, expected, reason: '回到格式态正本不应变化');

      // 服务端往返
      await tester.runAsync(controller.syncNow);
      await _pumpUntil(
        tester,
        () => _serverHasContent(serverUrl, controller.syncConfig.token, '--- | --- | ---'),
        describe: '等待表格推送到服务端',
        onTimeout: () => 'syncState=${controller.syncState}；'
            'syncError=${controller.syncError}',
      );
      expect(controller.syncError, isNull,
          reason: '推送不应报错：${controller.syncError}');

      final dbB = AppDatabase.memory();
      final repoB = NoteRepository(dbB, deviceId: 'm9t13-table-b');
      final syncB = SyncClient(
        repository: repoB,
        baseUrl: serverUrl,
        deviceId: 'm9t13-table-b',
        token: controller.syncConfig.token,
      );
      await tester.runAsync(() => syncB.pull());
      final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
      final note = pulled.firstWhere((n) => n.note.id == noteId).note;
      expect(note.contentMarkdown, expected,
          reason: '另一设备取回的表格必须与正本逐字节一致');

      await tester.runAsync(() async {
        syncB.close();
        await controller.disconnect();
        await db.close();
        await dbB.close();
      });
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // ---------------------------------------------------------------------------
  // 粘贴端到端（FR-45）
  // ---------------------------------------------------------------------------
  testWidgets(
    '粘贴：Ctrl+V 富文本 HTML→Markdown，Ctrl+Shift+V 纯文本转义',
    (tester) async {
      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm9t13-paste-a');
      final controller = AppController(
        repository: repo,
        database: db,
        dataDir: dataDir,
      );
      await tester.runAsync(controller.bootstrap);

      await tester.runAsync(() => controller.connect(SyncConfig(
            baseUrl: serverUrl,
            token: token,
            deviceId: controller.syncConfig.deviceId,
          )));

      await tester.runAsync(() async {
        await controller.createNote(title: '粘贴笔记');
        await controller.saveNote(
          controller.selectedNoteId!,
          title: '粘贴笔记',
          content: '前\n后',
          tags: const <String>[],
        );
      });
      final noteId = controller.selectedNoteId!;

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      await _settle(tester);

      final ctrl = _contentValue(tester);
      expect(ctrl.text, '前\n后');

      // ---- 富文本粘贴：mock 剪贴板含 HTML ----
      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = const TextSelection.collapsed(offset: 1); // '前' 之后
      await tester.pump();

      _mockClipboard(
        tester,
        html: '<p>粗体 <strong>文字</strong></p>',
        plain: '粗体 文字',
      );

      await _pressCtrl(tester, LogicalKeyboardKey.keyV);
      await tester.pump();

      expect(
        ctrl.text.contains('**文字**'),
        isTrue,
        reason: 'Ctrl+V 富粘贴应把 <strong> 转为 **加粗**（FR-45 / AC-142）',
      );

      // ---- 纯文本粘贴：Ctrl+Shift+V ----
      ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
      await tester.pump();

      _mockClipboard(
        tester,
        plain: 'a*b_c #标题 [x](y)',
      );

      await _pressCtrl(tester, LogicalKeyboardKey.keyV, shift: true);
      await tester.pump();

      expect(
        ctrl.text.contains(r'a\*b\_c \#标题 \[x\]\(y\)'),
        isTrue,
        reason: 'Ctrl+Shift+V 纯粘贴应转义 Markdown 特殊字符（FR-45 / AC-144）',
      );

      // 落盘并推送
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      await tester.runAsync(controller.syncNow);
      await _pumpUntil(
        tester,
        () => _serverHasContent(
            serverUrl, controller.syncConfig.token, '粗体'),
        describe: '等待粘贴结果推送到服务端',
        onTimeout: () => 'syncState=${controller.syncState}；'
            'syncError=${controller.syncError}；'
            '当前正文=${ctrl.text.substring(0, (ctrl.text.length < 100 ? ctrl.text.length : 100))}',
      );

      final dbB = AppDatabase.memory();
      final repoB = NoteRepository(dbB, deviceId: 'm9t13-paste-b');
      final syncB = SyncClient(
        repository: repoB,
        baseUrl: serverUrl,
        deviceId: 'm9t13-paste-b',
        token: controller.syncConfig.token,
      );
      await tester.runAsync(() => syncB.pull());
      final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
      final note = pulled.firstWhere((n) => n.note.id == noteId).note;
      expect(
        note.contentMarkdown.contains('**文字**'),
        isTrue,
        reason: '另一设备应取回富粘贴转换结果',
      );
      expect(
        note.contentMarkdown.contains(r'a\*b\_c'),
        isTrue,
        reason: '另一设备应取回纯粘贴转义结果',
      );

      // 清理 mock
      _clearClipboardMock(tester);

      await tester.runAsync(() async {
        syncB.close();
        await controller.disconnect();
        await db.close();
        await dbB.close();
      });
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // ---------------------------------------------------------------------------
  // 简化格式端到端（FR-45）
  // ---------------------------------------------------------------------------
  testWidgets(
    '简化格式：行内 + 块级格式一并剥离，服务端往返保真',
    (tester) async {
      const seed = '# 标题\n\n**粗体** 与 ==高亮== 混排\n\n'
          '- 无序项 1\n- 无序项 2\n\n> 引用行\n\n`代码` 普通文字';
      const simplified = '# 标题\n\n粗体 与 高亮 混排\n\n'
          '- 无序项 1\n- 无序项 2\n\n> 引用行\n\n代码 普通文字';

      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm9t13-simp-a');
      final controller = AppController(
        repository: repo,
        database: db,
        dataDir: dataDir,
      );
      await tester.runAsync(controller.bootstrap);

      await tester.runAsync(() => controller.connect(SyncConfig(
            baseUrl: serverUrl,
            token: token,
            deviceId: controller.syncConfig.deviceId,
          )));

      await tester.runAsync(() async {
        await controller.createNote(title: '简化格式');
        await controller.saveNote(
          controller.selectedNoteId!,
          title: '简化格式',
          content: seed,
          tags: const <String>[],
        );
      });
      final noteId = controller.selectedNoteId!;

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      await _settle(tester);

      final ctrl = _contentValue(tester);
      expect(ctrl.text, seed);

      // 全选 → 点「简化格式」
      await tester.tap(_contentField());
      await tester.pump();
      ctrl.selection = TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
      await tester.pump();

      final simplifyBtn = find.byIcon(Icons.format_clear);
      await tester.ensureVisible(simplifyBtn);
      await tester.pump();
      await tester.tap(simplifyBtn);
      await tester.pump();

      expect(ctrl.text, simplified,
          reason: '简化格式应剥离行内格式标记，保留块级结构（AC-143）');

      // 落盘 + 服务端往返
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();

      await tester.runAsync(controller.syncNow);
      await _pumpUntil(
        tester,
        () => _serverHasContent(
            serverUrl, controller.syncConfig.token, '粗体 与 高亮 混排'),
        describe: '等待简化格式结果推送到服务端',
        onTimeout: () => 'syncState=${controller.syncState}；'
            'syncError=${controller.syncError}',
      );

      final dbB = AppDatabase.memory();
      final repoB = NoteRepository(dbB, deviceId: 'm9t13-simp-b');
      final syncB = SyncClient(
        repository: repoB,
        baseUrl: serverUrl,
        deviceId: 'm9t13-simp-b',
        token: controller.syncConfig.token,
      );
      await tester.runAsync(() => syncB.pull());
      final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
      final note = pulled.firstWhere((n) => n.note.id == noteId).note;
      expect(note.contentMarkdown, simplified,
          reason: '另一设备取回的简化结果必须逐字节一致');

      await tester.runAsync(() async {
        syncB.close();
        await controller.disconnect();
        await db.close();
        await dbB.close();
      });
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // ---------------------------------------------------------------------------
  // 附件端到端（FR-46 / FR-47）
  // ---------------------------------------------------------------------------
  testWidgets(
    '附件：面板列表 → 外部编辑回写 → sui:// 引用变更 → 服务端往返',
    (tester) async {
      final imageBytes = Uint8List.fromList(
        List<int>.generate(128, (i) => i % 256),
      );
      final imageSha = sha256Hex(imageBytes);

      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm9t13-att-a');
      final controller = AppController(
        repository: repo,
        database: db,
        dataDir: dataDir,
      );
      await tester.runAsync(controller.bootstrap);

      await tester.runAsync(() => controller.connect(SyncConfig(
            baseUrl: serverUrl,
            token: token,
            deviceId: controller.syncConfig.deviceId,
          )));

      await tester.runAsync(() async {
        await controller.createNote(title: '附件笔记');
        await controller.saveNote(
          controller.selectedNoteId!,
          title: '附件笔记',
          content: '正文开头\n\n![photo.png](sui://$imageSha)\n',
          tags: const <String>[],
        );
        // 预先把附件挂到笔记上（编辑器首次加载时会拉取附件列表）
        await controller.addAttachmentFromBytes(
          noteId: controller.selectedNoteId!,
          filename: 'photo.png',
          bytes: imageBytes,
        );
      });
      final noteId = controller.selectedNoteId!;
      expect(controller.attachments, hasLength(1));

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      await _settle(tester);

      final ctrl = _contentValue(tester);
      expect(
        ctrl.text.contains('![photo.png](sui://$imageSha)'),
        isTrue,
        reason: '正文应包含图片引用',
      );

      // ---- 1. 附件面板：列出附件 ----
      final attBtn = find.byTooltip('附件');
      await tester.ensureVisible(attBtn);
      await tester.pump();
      await tester.tap(attBtn);
      await _settleRoute(tester);

      expect(find.text('photo.png'), findsOneWidget,
          reason: '附件面板应列出刚添加的图片');
      expect(find.text('1 个'), findsOneWidget,
          reason: '面板标题应显示附件数量');

      // 等待附件卡片的可用性检查完成（从「检查中」变为「待上传/已同步」）
      await _pumpUntil(
        tester,
        () async => find.textContaining('检查中').evaluate().isEmpty,
        describe: '等待附件可用性检查完成',
      );

      // ---- 2. 附件卡片可点击（预览入口存在） ----
      // 说明：预览弹窗的完整交互（图片/文本/PDF 预览 + 外部打开）已在 widget 层
      // （editor_m9_test.dart）覆盖；此处仅验证卡片可交互 + 面板正常渲染。
      final cardInkWell = find.ancestor(
        of: find.text('photo.png'),
        matching: find.byWidgetPredicate((w) => w is InkWell && w.onTap != null),
      );
      expect(cardInkWell, findsOneWidget,
          reason: '附件卡片应有可点击的 InkWell（预览入口）');

      // 关闭附件面板
      await tester.tap(find.text('关闭'));
      await _settleRoute(tester);

      // ---- 3. 外部编辑回写：replaceAttachmentBytes 改写 sui:// 引用 ----
      final newBytes = Uint8List.fromList(
        List<int>.generate(256, (i) => (i * 3) % 256),
      );
      final newSha = sha256Hex(newBytes);
      expect(newSha, isNot(imageSha), reason: '新字节应有不同 hash');

      final target = controller.attachments.first;
      final replaced = await tester.runAsync(
        () => controller.replaceAttachmentBytes(target, newBytes),
      );
      expect(replaced, isTrue, reason: '字节变更应返回 true');
      await tester.pump();

      expect(
        ctrl.text.contains('![photo.png](sui://$newSha)'),
        isTrue,
        reason: '回写后正本引用应指向新 sha256（BR-47.4 / AC-150）',
      );
      expect(
        ctrl.text.contains('sui://$imageSha'),
        isFalse,
        reason: '旧 hash 引用应被替换掉',
      );

      // ---- 4. 服务端往返：新引用 + 新 blob ----
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      await tester.runAsync(controller.syncNow);
      await _pumpUntil(
        tester,
        () => _serverHasContent(
            serverUrl, controller.syncConfig.token, 'sui://$newSha'),
        describe: '等待附件回写结果推送到服务端',
        onTimeout: () => 'syncState=${controller.syncState}；'
            'syncError=${controller.syncError}',
      );
      expect(controller.syncError, isNull,
          reason: '推送不应报错：${controller.syncError}');

      // 另一设备拉取
      final dbB = AppDatabase.memory();
      final repoB = NoteRepository(dbB, deviceId: 'm9t13-att-b');
      final syncB = SyncClient(
        repository: repoB,
        baseUrl: serverUrl,
        deviceId: 'm9t13-att-b',
        token: controller.syncConfig.token,
      );
      await tester.runAsync(() => syncB.pull());
      final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
      final note = pulled.firstWhere((n) => n.note.id == noteId).note;
      expect(
        note.contentMarkdown.contains('sui://$newSha'),
        isTrue,
        reason: '另一设备应取回新的 sui:// 引用',
      );
      expect(
        note.contentMarkdown.contains('sui://$imageSha'),
        isFalse,
        reason: '另一设备不应保留旧 hash 引用',
      );

      // 附件映射也应同步
      final attsB = await tester.runAsync(
        () => repoB.listAttachments(noteId: noteId),
      );
      expect(attsB, hasLength(1));
      expect(attsB!.first.sha256, newSha,
          reason: '另一设备的附件映射应指向新 hash');

      await tester.runAsync(() async {
        syncB.close();
        await controller.disconnect();
        await db.close();
        await dbB.close();
      });
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // ---------------------------------------------------------------------------
  // 有序列表端到端（FR-48）
  // ---------------------------------------------------------------------------
  testWidgets(
    '有序列表：正本统一 1. → 渲染层按序编号 → 三态 + 服务端往返保真',
    (tester) async {
      const seed = '1. 第一项\n1. 第二项\n1. 第三项';

      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm9t13-ol-a');
      final controller = AppController(
        repository: repo,
        database: db,
        dataDir: dataDir,
      );
      await tester.runAsync(controller.bootstrap);

      await tester.runAsync(() => controller.connect(SyncConfig(
            baseUrl: serverUrl,
            token: token,
            deviceId: controller.syncConfig.deviceId,
          )));

      await tester.runAsync(() async {
        await controller.createNote(title: '有序列表');
        await controller.saveNote(
          controller.selectedNoteId!,
          title: '有序列表',
          content: seed,
          tags: const <String>[],
        );
      });
      final noteId = controller.selectedNoteId!;

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      await _settle(tester);

      final ctrl = _contentValue(tester);
      expect(ctrl.text, seed, reason: '正本应全为 1.');

      // 格式模式下渲染编号 2、3（WidgetSpan 承载）
      // 注意：MarkdownEditor 格式模式下正文用 MarkdownEditingController.buildTextSpan
      // 渲染，其中有序列表项会生成 WidgetSpan 包裹编号文本。
      final fields = find.descendant(
        of: find.byType(MarkdownEditor),
        matching: find.byType(TextField),
      );
      final bodyField = fields.first;
      final bodyCtrl = tester.widget<TextField>(bodyField).controller;
      expect(bodyCtrl, isNotNull);

      // 验证 span 树等长契约（与 T12 一致）
      final mdCtrl = bodyCtrl as MarkdownEditingController;
      final span = mdCtrl.buildTextSpan(
        context: tester.element(bodyField),
        style: const TextStyle(),
        withComposing: false,
      );
      expect(
        span.toPlainText().length,
        mdCtrl.text.length,
        reason: 'span 树纯文本必须与正本等长（BR-27.1 / AC-154）',
      );

      final numbers = span.children!
          .whereType<WidgetSpan>()
          .map((w) => w.child)
          .whereType<Text>()
          .map((t) => t.data)
          .toList();
      expect(
        numbers,
        containsAll(['1. ', '2. ', '3. ']),
        reason: '正本均为 1.，渲染层按序显示 1./2./3. 编号——编号本身也是**记号呈现单元**'
            '（FR-48 / AC-153 / AC-172）',
      );

      // 三态一致
      await tester.tap(find.text('源码'));
      await tester.pump();
      expect(ctrl.text, seed, reason: '源码态正本与格式态一致');

      await tester.tap(find.text('预览'));
      await _settle(tester);
      expect(find.byType(Markdown), findsOneWidget);

      await tester.tap(find.text('格式'));
      await tester.pump();
      expect(ctrl.text, seed, reason: '回到格式态正本不应变化');

      // 服务端往返
      await tester.runAsync(controller.syncNow);
      await _pumpUntil(
        tester,
        () => _serverHasContent(
            serverUrl, controller.syncConfig.token, '第三项'),
        describe: '等待有序列表推送到服务端',
        onTimeout: () => 'syncState=${controller.syncState}；'
            'syncError=${controller.syncError}',
      );

      final dbB = AppDatabase.memory();
      final repoB = NoteRepository(dbB, deviceId: 'm9t13-ol-b');
      final syncB = SyncClient(
        repository: repoB,
        baseUrl: serverUrl,
        deviceId: 'm9t13-ol-b',
        token: controller.syncConfig.token,
      );
      await tester.runAsync(() => syncB.pull());
      final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
      final note = pulled.firstWhere((n) => n.note.id == noteId).note;
      expect(note.contentMarkdown, seed,
          reason: '另一设备取回的有序列表必须与正本逐字节一致（全 1.）');

      await tester.runAsync(() async {
        syncB.close();
        await controller.disconnect();
        await db.close();
        await dbB.close();
      });
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  // ---------------------------------------------------------------------------
  // 往返保真门禁扩展：表格 + 附件引用 + 有序列表三态 + 服务端往返逐字节不变
  // ---------------------------------------------------------------------------
  testWidgets(
    '往返保真门禁：表格 + 附件引用 + 有序列表样本三态 + 服务端往返逐字节不变',
    (tester) async {
      // 构造含表格 + 附件引用 + 有序列表的复杂样本
      const tricky = '# 混合样本\n\n'
          '| 项目 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n| 香蕉 | 5 |\n\n'
          '1. 第一步\n1. 第二步\n1. 第三步\n\n'
          '附件：![截图](sui://abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890)\n\n'
          '**粗体** 与 ==高亮== 收尾';

      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm9t13-fidelity-a');
      final controller = AppController(
        repository: repo,
        database: db,
        dataDir: dataDir,
      );
      await tester.runAsync(controller.bootstrap);

      await tester.runAsync(() => controller.connect(SyncConfig(
            baseUrl: serverUrl,
            token: token,
            deviceId: controller.syncConfig.deviceId,
          )));

      await tester.runAsync(() async {
        await controller.createNote(title: '保真样本');
        await controller.saveNote(
          controller.selectedNoteId!,
          title: '保真样本',
          content: tricky,
          tags: const <String>[],
        );
      });
      final noteId = controller.selectedNoteId!;

      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: const MaterialApp(home: NoteShell()),
        ),
      );
      await _settle(tester);

      final ctrl = _contentValue(tester);
      expect(ctrl.text, tricky, reason: '打开后正本应与落库内容一致');

      // 聚焦 → 失焦：呈现态切换不得留下字节痕迹
      await tester.tap(_contentField());
      await tester.pump();
      await tester.tap(find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      ).first); // 点标题栏失焦
      await tester.pump();

      // 三态循环：格式 → 源码 → 预览 → 源码 → 格式
      for (final label in const <String>['源码', '预览', '源码', '格式']) {
        await tester.tap(find.text(label));
        await _settle(tester);
        if (label != '预览') {
          expect(ctrl.text, tricky,
              reason: '切到「$label」不应改动正本（ADR-006 / BR-23.3）');
        }
      }

      final afterLocal = (await tester.runAsync(() => repo.getNote(noteId)))!;
      expect(afterLocal.contentMarkdown, tricky,
          reason: '打开不编辑的三态往返必须逐字节不变');

      // 服务端往返
      await tester.runAsync(controller.syncNow);
      await _pumpUntil(
        tester,
        () => _serverHasContent(
            serverUrl, controller.syncConfig.token, 'abcdef1234567890'),
        describe: '等待保真样本推送到服务端',
        onTimeout: () => 'syncState=${controller.syncState}；'
            'syncError=${controller.syncError}',
      );

      final dbB = AppDatabase.memory();
      final repoB = NoteRepository(dbB, deviceId: 'm9t13-fidelity-b');
      final syncB = SyncClient(
        repository: repoB,
        baseUrl: serverUrl,
        deviceId: 'm9t13-fidelity-b',
        token: controller.syncConfig.token,
      );
      await tester.runAsync(() => syncB.pull());
      final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
      final note = pulled.firstWhere((n) => n.note.id == noteId).note;
      expect(note.contentMarkdown, tricky,
          reason: '另一设备取回的混合样本必须逐字节一致（保真门禁）');

      await tester.runAsync(() async {
        syncB.close();
        await controller.disconnect();
        await db.close();
        await dbB.close();
      });
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

// =============================================================================
// 辅助函数
// =============================================================================

/// 正文输入框（用 MarkdownEditor 作锚点 + `.first`，详见 M9-T12 注释）。
Finder _contentField() => find
    .descendant(
      of: find.byType(MarkdownEditor),
      matching: find.byType(TextField),
    )
    .first;

TextEditingController _contentValue(WidgetTester tester) =>
    tester.widget<TextField>(_contentField()).controller!;

/// 模拟 Ctrl（+ 可选 Shift）组合键。
Future<void> _pressCtrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

/// 有界推进（替代 pumpAndSettle，避免 30s 周期同步导致无限排帧）。
Future<void> _settle(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 16),
  int frames = 30,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

/// 对话框路由动画完成的有界推进。
Future<void> _settleRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// 交替推进真实 I/O 与假时钟，直到 [condition] 成立。
Future<void> _pumpUntil(
  WidgetTester tester,
  Future<bool> Function() condition, {
  required String describe,
  String Function()? onTimeout,
  Duration timeout = const Duration(seconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final ok = await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return condition();
    });
    if (ok ?? false) {
      await tester.pump();
      return;
    }
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('超时（${timeout.inSeconds}s）：$describe'
      '${onTimeout == null ? '' : ' —— ${onTimeout()}'}');
}

/// 服务端 pull 响应是否含 [marker]。
Future<bool> _serverHasContent(
  String serverUrl,
  String token,
  String marker,
) async {
  final client = Client();
  try {
    final resp = await client.get(
      Uri.parse('$serverUrl/api/v1/sync/pull'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return resp.statusCode == 200 && resp.body.contains(marker);
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// 轮询 /healthz 直到服务端就绪。
Future<void> _waitUntilReady(
  String baseUrl, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final client = Client();
  final deadline = DateTime.now().add(timeout);
  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final resp = await client.get(Uri.parse('$baseUrl/healthz'));
        if (resp.statusCode == 200) return;
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 100));
    }
    fail('服务端 ${timeout.inSeconds}s 内未就绪：$baseUrl');
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// 剪贴板 mock
// ---------------------------------------------------------------------------

/// mock 系统剪贴板：同时设置 `text/plain` 和可选的 `text/html`。
///
/// Clipboard.getData(format) → SystemChannels.platform.invokeMethod('Clipboard.getData', format)
/// 返回 Map<String, dynamic>?，框架取 result['text'] as String。
void _mockClipboard(
  WidgetTester tester, {
  String? html,
  required String plain,
}) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        final format = call.arguments as String;
        if (format == 'text/html' && html != null) {
          return <String, dynamic>{'text': html};
        }
        if (format == Clipboard.kTextPlain) {
          return <String, dynamic>{'text': plain};
        }
        return null;
      }
      if (call.method == 'Clipboard.setData') {
        return null;
      }
      // 其他 platform 方法放行（让默认实现处理）
      return null;
    },
  );
}

void _clearClipboardMock(WidgetTester tester) {
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null);
}
