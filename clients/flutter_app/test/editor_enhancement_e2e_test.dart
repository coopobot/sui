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
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// M5-T12 编辑器增强端到端验证（editor-formatting.md §8 / §9 / §10 / §11；todolist M5-T12）。
///
/// 与 M5-T11 的 widget 测试不同：这里拉起**真实 Go 服务端进程**，把「快捷键 / 勾选框 /
/// 高亮 / 聚焦式呈现」这套增强从「点控件、按快捷键」一路走到「数据落到服务端、另一台
/// 设备原样取回」，验证三态一致与往返逐字节保真不回归。
///
/// 覆盖：AC-86（快捷键应用）、AC-88（作用域）、AC-89（勾选框切换）、AC-90（高亮渲染）、
/// AC-91（聚焦呈现往返保真）、AC-93（增强不换正本 / 落库逐字节一致）。
void main() {
  const port = 18098;
  const serverUrl = 'http://127.0.0.1:$port';
  const password = 'pw123';

  late Process server;
  late String dataDir;
  late String serverBin;
  late String token;

  setUpAll(() async {
    // `TestWidgetsFlutterBinding` 会装一个 HttpOverrides，把请求一律挡成 400，
    // 真服务端永远探活不成功 —— 本文件就是要打真服务端，必须撤掉。
    HttpOverrides.global = null;

    final repoRoot = Directory.current.parent.parent.path;
    dataDir = '${Directory.systemTemp.path}/sui-editor-e2e-'
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

    // M4/BR-33.2：服务端为单用户实例，首次启动后仅允许创建唯一账号，此后注册网关
    // 关闭。因此在本组用例开头做一次性注册并记下会话 Token，各用例复用；否则第二个
    // 用例再走「注册并连接」会拿到「该服务端已初始化」而被拒。
    final client = Client();
    try {
      final regResp = await client.post(
        Uri.parse('$serverUrl/api/v1/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': 'm5t12', 'password': password}),
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

  testWidgets(
    '编辑增强端到端：快捷键 + 勾选框 + 高亮三态一致并经服务端往返保真',
    (tester) async {
      const seed = '重点\n- [ ] 买牛奶\n==高亮块==';
      const afterBold = '**重点**\n- [ ] 买牛奶\n==高亮块==';
      const afterToggle = '**重点**\n- [x] 买牛奶\n==高亮块==';

      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm5t12-a');
      final controller = AppController(repository: repo, database: db);
      await tester.runAsync(controller.bootstrap);

      // 复用 setUpAll 中一次性注册得到的会话 Token 直连（单用户实例不能重复注册）。
      // 连接入口本身已由 `ui_server_integration_test` 从对话框覆盖，这里聚焦编辑增强。
      await tester.runAsync(() => controller.connect(SyncConfig(
            baseUrl: serverUrl,
            token: token,
            deviceId: controller.syncConfig.deviceId,
          )));
      expect(controller.syncClient, isNotNull, reason: 'SyncClient 应已实例化');

      await tester.runAsync(() async {
        await controller.createNote(title: '编辑增强');
        await controller.saveNote(
          controller.selectedNoteId!,
          title: '编辑增强',
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

      final contentField = find
          .descendant(
            of: find.byType(NoteEditor),
            matching: find.byType(TextField),
          )
          .last;
      final ctrl = tester.widget<TextField>(contentField).controller!;
      expect(ctrl.text, seed, reason: '打开后正文正本应与落库内容一致');

      // ---- 快捷键：选中「重点」→ Ctrl+B 加粗（与工具栏同源，AC-86 / BR-30.4）----
      await tester.tap(contentField);
      await tester.pump();
      ctrl.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pump();
      await _pressCtrl(tester, LogicalKeyboardKey.keyB);
      await tester.pump();
      expect(ctrl.text, afterBold, reason: 'Ctrl+B 应把选区加粗（AC-86）');

      // ---- 勾选框：点选格式模式内联勾选框 → 原地翻转 [ ]→[x]（AC-89 / BR-31.2）----
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget,
          reason: '格式模式应把任务项渲染为可点选复选框（§10.1）');
      await tester.tap(find.byIcon(Icons.check_box_outline_blank));
      await tester.pump();
      expect(find.byIcon(Icons.check_box), findsOneWidget,
          reason: '点选后勾选框应转为已勾选态');
      expect(ctrl.text, afterToggle,
          reason: '切换只应翻转方括号内一个字符（BR-31.2）');

      // 落盘（`_save` 异步，给真实 I/O 让路）
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pump();
      final persisted = (await tester.runAsync(() => repo.getNote(noteId)))!;
      expect(persisted.contentMarkdown, afterToggle,
          reason: '增强编辑必须即时落到正本（AC-93）');

      // ---- 三态一致：格式 / 源码共用同一正本，切换不改字节（ADR-006）----
      await tester.tap(find.text('源码'));
      await tester.pump();
      expect(ctrl.text, afterToggle, reason: '源码态正本与格式态一致');

      await tester.tap(find.text('预览'));
      await _settle(tester);
      expect(find.byType(Markdown), findsOneWidget);
      final want = Theme.of(tester.element(find.byType(Markdown)))
          .colorScheme
          .tertiaryContainer;
      // 预览态默认 `selectable: true`，flutter_markdown 用 SelectableText 而非
      // RichText 承载行内 span，两处都要取（见 M5-T11 同款处理）。
      final spans = <InlineSpan>[
        ...tester.widgetList<RichText>(find.byType(RichText)).map((rt) => rt.text),
        ...tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((st) => st.textSpan ?? const TextSpan()),
      ];
      expect(spans.any((s) => _spanHasBackground(s, want)), isTrue,
          reason: '预览态 ==高亮== 应渲染为高亮底色（BR-31.5 / AC-90）');
      expect(find.textContaining('买牛奶'), findsWidgets,
          reason: '预览态应含任务文本');

      await tester.tap(find.text('格式'));
      await tester.pump();
      expect(ctrl.text, afterToggle, reason: '回到格式态正本不应变化');

      final afterCycle = (await tester.runAsync(() => repo.getNote(noteId)))!;
      expect(afterCycle.contentMarkdown, afterToggle,
          reason: '三态往返不得改动正本（BR-32.1 / AC-91）');

      // ---- 服务端往返：推送 → 另一设备（独立库 / deviceId）原样取回 ----
      await tester.runAsync(controller.syncNow);
      await _pumpUntil(
        tester,
        () => _serverHasContent(
            serverUrl, controller.syncConfig.token, '买牛奶'),
        describe: '等待增强编辑推送到服务端',
        onTimeout: () => 'syncState=${controller.syncState}；'
            'syncError=${controller.syncError}',
      );
      expect(controller.syncError, isNull,
          reason: '推送不应报错：${controller.syncError}');

      final dbB = AppDatabase.memory();
      final repoB = NoteRepository(dbB, deviceId: 'm5t12-b');
      final syncB = SyncClient(
        repository: repoB,
        baseUrl: serverUrl,
        deviceId: 'm5t12-b',
        token: controller.syncConfig.token,
      );
      await tester.runAsync(() => syncB.pull());
      final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
      final note = pulled.firstWhere((n) => n.note.id == noteId).note;
      expect(note.contentMarkdown, afterToggle,
          reason: '另一设备取回的正文必须与正本逐字节一致');

      await tester.runAsync(() async {
        syncB.close();
        await controller.disconnect();
        await db.close();
        await dbB.close();
      });
      // `disconnect` 已取消周期同步定时器；推进假时钟让 WS 关闭握手的内部超时
      // 定时器触发释放，避免用例结束仍有挂起定时器被判失败。
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    '打开不编辑跨三态往返逐字节保真不回归（AC-91 / AC-93）',
    (tester) async {
      const tricky = '# 标题\n\n**粗体** 与 ==高亮== 混排\n'
          '- [x] 已完成\n- [ ] 待办\n> 引用行';

      final db = AppDatabase.memory();
      final repo = NoteRepository(db, deviceId: 'm5t12-c');
      final controller = AppController(repository: repo, database: db);
      await tester.runAsync(controller.bootstrap);

      await tester.runAsync(() => controller.connect(SyncConfig(
            baseUrl: serverUrl,
            token: token,
            deviceId: controller.syncConfig.deviceId,
          )));
      expect(controller.syncClient, isNotNull, reason: 'SyncClient 应已实例化');

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

      final fields = find.descendant(
        of: find.byType(NoteEditor),
        matching: find.byType(TextField),
      );
      final ctrl = tester.widget<TextField>(fields.last).controller!;
      expect(ctrl.text, tricky, reason: '打开后正本应与落库内容一致');

      // 聚焦正文 → 点标题栏失焦：呈现态切换不得留下任何字节痕迹。
      await tester.tap(fields.last);
      await tester.pump();
      await tester.tap(fields.first);
      await tester.pump();

      for (final label in const <String>['源码', '预览', '源码', '格式']) {
        await tester.tap(find.text(label));
        await _settle(tester);
        if (label != '预览') {
          expect(ctrl.text, tricky, reason: '切到「$label」不应改动正本');
        }
      }

      final after = (await tester.runAsync(() => repo.getNote(noteId)))!;
      expect(after.contentMarkdown, tricky,
          reason: '打开不编辑的往返必须逐字节不变（ADR-006 / BR-23.3）');

      // 服务端往返同样逐字节保真。
      await tester.runAsync(controller.syncNow);
      await _pumpUntil(
        tester,
        () => _serverHasContent(
            serverUrl, controller.syncConfig.token, '待办'),
        describe: '等待样本推送到服务端',
        onTimeout: () => 'syncState=${controller.syncState}；'
            'syncError=${controller.syncError}',
      );

      final dbB = AppDatabase.memory();
      final repoB = NoteRepository(dbB, deviceId: 'm5t12-d');
      final syncB = SyncClient(
        repository: repoB,
        baseUrl: serverUrl,
        deviceId: 'm5t12-d',
        token: controller.syncConfig.token,
      );
      await tester.runAsync(() => syncB.pull());
      final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
      final note = pulled.firstWhere((n) => n.note.id == noteId).note;
      expect(note.contentMarkdown, tricky,
          reason: '另一设备取回的样本必须逐字节一致');

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

/// 模拟 Ctrl（+ 可选 Shift）组合键：按下修饰键 → 按目标键 → 依次抬起。
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

/// span（含子 span）中是否含指定底色（用于校验预览态高亮渲染）。
bool _spanHasBackground(InlineSpan span, Color want) {
  if (span is! TextSpan) return false;
  if (span.style?.backgroundColor == want) return true;
  return (span.children ?? const <InlineSpan>[])
      .any((c) => _spanHasBackground(c, want));
}

/// 有界推进：走完路由 / 对话框 / 渲染的过渡动画，但绝不无限等待。
///
/// 不能用 `pumpAndSettle()`：连接成功后 `AppController` 挂了 30s 周期兜底同步，
/// 状态切到 `syncing` 时顶栏渲染不定长的 `CircularProgressIndicator`，无限排帧。
/// 这里按帧推进固定时长（30 × 16ms = 480ms，远小于 30s 周期），安全。
Future<void> _settle(
  WidgetTester tester, {
  Duration step = const Duration(milliseconds: 16),
  int frames = 30,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
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

/// 直接问服务端：该账号的 pull 响应里是否含 [marker]（用最朴素的子串判断即可）。
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

/// 轮询 `/healthz` 直到服务端就绪（不用固定 sleep，避免机器繁忙时假失败）。
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
      } catch (_) {
        // 还没起来（连接被拒），继续等。
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    fail('服务端 ${timeout.inSeconds}s 内未就绪：$baseUrl');
  } finally {
    client.close();
  }
}
