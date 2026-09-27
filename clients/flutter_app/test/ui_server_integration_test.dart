@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/note_editor.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// UI 级联调：驱动真实控件树（NoteShell + 同步设置对话框 + 编辑器），
/// 对真实 Go 服务端进程完成「注册连接 → 新建笔记 → 编辑 → 同步」，
/// 最后用另一台设备从服务端拉取，证明数据真的落到了服务端。
///
/// 与 `sync_wiring_test.dart` 的区别：那个测的是 `AppController` 的接线，
/// 不碰控件；这里从「点按钮、填输入框」一路走到服务端，覆盖 UI 到网络的全链路。
///
/// 之所以不放在浏览器里跑：Flutter Web 渲染进 canvas，自动化点坐标不可靠，
/// 而文本输入走隐藏 DOM input，键入经常落不进去 —— 实测表现为「地址填了却没生效，
/// 请求仍打默认的 127.0.0.1:8080」。控件测试的 `enterText` 直接作用于
/// `TextEditingController`，没有这类不确定性。
void main() {
  const port = 18097;
  const serverUrl = 'http://127.0.0.1:$port';
  const username = 'ui-e2e-user';
  const password = 'pw123';
  const noteTitle = '联调验证笔记';
  const noteBody = 'hello from ui client';

  late Process server;
  late String dataDir;
  late String serverBin;

  setUpAll(() async {
    // `TestWidgetsFlutterBinding` 会装一个 HttpOverrides，把所有请求挡成 400，
    // 真服务端永远探活不成功。这里显式撤掉 —— 本文件就是要打真服务端，
    // mock 掉网络等于什么都没测。
    HttpOverrides.global = null;

    final repoRoot = Directory.current.parent.parent.path;
    dataDir =
        '${Directory.systemTemp.path}/sui-ui-e2e-${DateTime.now().millisecondsSinceEpoch}';
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
  });

  tearDownAll(() async {
    server.kill();
    await server.exitCode;
    try {
      await Directory(dataDir).delete(recursive: true);
    } catch (_) {}
  });

  testWidgets('UI 联调：设置对话框注册 → 新建笔记 → 另一设备从服务端拉到', (tester) async {
    final db = AppDatabase.memory();
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'ui-dev-a'),
      database: db,
    );
    await tester.runAsync(controller.bootstrap);

    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: NoteShell()),
      ),
    );
    await _settle(tester);

    // 未配置：顶栏云朵提示「未连接服务端 · 点击配置」
    expect(find.byTooltip('未连接服务端 · 点击配置'), findsOneWidget);

    // 打开同步设置对话框
    await tester.tap(find.byTooltip('同步设置'));
    await _settle(tester);
    expect(find.text('注册并连接'), findsOneWidget);

    // 对话框内文本框顺序：服务端地址 / 用户名 / 密码 / Token / 缓存上限(MB)
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(5));
    await tester.enterText(fields.at(0), serverUrl);
    await tester.enterText(fields.at(1), username);
    await tester.enterText(fields.at(2), password);
    await tester.pump();

    // 注册并连接：注册 HTTP → connect → WS → 首次 syncNow，一条链上多轮真实 I/O，
    // 必须反复交替「给真实 I/O 时间」与「推进假时钟微任务」。
    await tester.tap(find.text('注册并连接'));
    await tester.pump();
    await _pumpUntil(
      tester,
      () async => find.text('注册成功，已连接').evaluate().isNotEmpty,
      describe: '等待注册连接完成（对话框提示）',
      onTimeout: () => '对话框当前文本：${_dialogText(tester)}；'
          'syncError=${controller.syncError}',
    );
    expect(controller.syncClient, isNotNull, reason: 'SyncClient 应已实例化');

    await tester.tap(find.text('关闭'));
    await _settle(tester);

    // 新建笔记并编辑：标题 onChanged 立即保存，正文另有 400ms 防抖
    await tester.tap(find.byTooltip('新建笔记'));
    await _pumpUntil(
      tester,
      () async => controller.selectedNoteId != null,
      describe: '等待新建笔记被选中',
    );

    final editorFields = find.descendant(
      of: find.byType(NoteEditor),
      matching: find.byType(TextField),
    );
    await tester.enterText(editorFields.first, noteTitle);
    await tester.pump();
    await tester.enterText(editorFields.last, noteBody);
    await tester.pump();

    // 等笔记真的落到服务端。不能等 `lastSyncedAt`：它在 connect 阶段的首次
    // syncNow 就已写入，等于没等这次推送。直接问服务端最实在。
    await _pumpUntil(
      tester,
      () => _serverHasNote(serverUrl, controller.syncConfig.token, noteTitle),
      describe: '等待笔记推送到服务端',
      onTimeout: () => 'syncState=${controller.syncState}；'
          'syncError=${controller.syncError}',
    );
    expect(controller.syncError, isNull, reason: '推送不应报错：${controller.syncError}');

    // 独立验证：另一台设备（独立库、独立 deviceId）从服务端拉取。
    // 这里直接用 `SyncClient` 而不是第二个 `AppController`：后者会顺带拉起
    // WebSocket 与 30s 周期定时器，在 widget 测试的假时钟里很难干净收尾，
    // 而本步要证的只是「服务端那份数据能被别的设备取走」。
    final dbB = AppDatabase.memory();
    final repoB = NoteRepository(dbB, deviceId: 'ui-dev-b');
    final syncB = SyncClient(
      repository: repoB,
      baseUrl: serverUrl,
      deviceId: 'ui-dev-b',
      token: controller.syncConfig.token,
    );
    await tester.runAsync(() async {
      await syncB.pull();
    });

    // 读本地库同样是真实 I/O：`testWidgets` 跑在假时钟里，不在 `runAsync` 中 await
    // 的 Future 永远等不到完成 —— 表现是整个用例静默卡到 10 分钟测试超时。
    final pulled = (await tester.runAsync(() => repoB.listNotes()))!;
    final titles = pulled.map((n) => n.note.title).toList();
    expect(titles, contains(noteTitle), reason: '第二台设备应拉到经 UI 创建的笔记');
    final note = pulled.firstWhere((n) => n.note.title == noteTitle).note;
    expect(note.contentMarkdown, contains(noteBody), reason: '正文也应同步过去');

    await tester.runAsync(() async {
      syncB.close();
      await controller.disconnect();
      await db.close();
      await dbB.close();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// 有界推进：把路由/对话框的过渡动画走完，但绝不无限等待。
///
/// 不能用 `pumpAndSettle()`。连接成功后 `AppController` 会挂一个 30s 的
/// `Timer.periodic` 兜底同步；而 `SyncState.syncing` 时顶栏渲染的是不定长的
/// `CircularProgressIndicator`。`pumpAndSettle` 会不断推进假时钟直到「没有待处理帧」——
/// 时钟一旦被推过 30s，周期定时器触发 `syncNow` 把状态切成 `syncing`，
/// 那个转圈动画就永远在排帧，于是整个用例静默卡到 10 分钟测试超时。
/// 这里按帧推进固定时长（30 × 16ms = 480ms，远小于 30s 的周期同步间隔），
/// 足够走完对话框的进出场动画，又不会碰到那个定时器。
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
///
/// `testWidgets` 跑在假时钟里，真实网络完成回调要等假时钟 flush 才送达；而
/// 单次 `runAsync` 又只放行一轮真实 I/O。凡是「点一下按钮会连带发起多轮请求」
/// 的地方（注册 → connect → 首次 sync），就得这样来回推。
Future<void> _pumpUntil(
  WidgetTester tester,
  Future<bool> Function() condition, {
  required String describe,
  String Function()? onTimeout,
  Duration timeout = const Duration(seconds: 25),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    // 每轮必须先在真实事件循环上让出一点时间，否则 socket 收发永远推进不了；
    // 紧接着 pump 一次，把这一轮攒下的假时钟微任务（await 链的后续）跑掉。
    final ok = await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return condition();
    });
    if (ok ?? false) {
      // 条件读的是 controller 状态，控件树还差一帧才反映出来；不补这一帧，
      // 紧接着的 find.byType 会找不到刚出现的编辑器。
      await tester.pump();
      return;
    }
    // 每次只推 16ms：等待期间最多循环 ~200 轮，累计假时钟仍远小于 30s，
    // 不会把兜底周期同步定时器推进去（推进去会搅乱正在等的这轮同步）。
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('超时（${timeout.inSeconds}s）：$describe'
      '${onTimeout == null ? '' : ' —— ${onTimeout()}'}');
}

/// 直接问服务端：该账号下是否已有标题为 [title] 的笔记。
///
/// 用最朴素的子串判断即可 —— pull 的响应体里含标题与正文，
/// 这里要证的是「数据确实到了服务端」，不需要再解析一遍协议。
Future<bool> _serverHasNote(String serverUrl, String token, String title) async {
  final client = Client();
  try {
    final resp = await client.get(
      Uri.parse('$serverUrl/api/v1/sync/pull'),
      headers: {'Authorization': 'Bearer $token'},
    );
    return resp.statusCode == 200 && resp.body.contains(title);
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// 读出对话框当前展示的全部文本（失败时用于定位原因）。
String _dialogText(WidgetTester tester) {
  return tester
      .widgetList<Text>(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Text),
      ))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .join(' | ');
}

/// 轮询 `/healthz` 直到服务端就绪（不用固定 sleep，避免机器繁忙时假失败）。
Future<void> _waitUntilReady(String baseUrl,
    {Duration timeout = const Duration(seconds: 20)}) async {
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