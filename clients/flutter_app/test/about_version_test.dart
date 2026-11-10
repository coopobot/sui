/// FR-56 各客户端「关于」版本呈现 widget 测试（ADR-020 / ui-spec §21 / AC-198~AC-204）。
///
/// **纪律**：全程**禁用 `pumpAndSettle()`**，改用有界 `pump`（Agents.md §5.2）——
/// 连接服务端后 `AppController` 会挂 30s 周期同步器，`pumpAndSettle()` 推过 30s 后
/// 顶栏会出现不定长进度指示器 → 永远排帧、永不返回。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/app_version.dart';
import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/app_menu_bar.dart';
import 'package:sui_flutter_app/src/ui/desktop_commands.dart';
import 'package:sui_flutter_app/src/ui/note_shell.dart';

/// 有界推进：30 × 16ms = 480ms，远小于 30s 周期同步器（Agents.md §5.2）。
Future<void> _settle(WidgetTester tester, {int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('关于对话框显示当前版本号（AC-198 / AC-200 / AC-204）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showSuiAboutDialog(context),
                child: const Text('打开关于'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开关于'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 版本号必须来自构建期常量（真源派生），用例内**不硬编码**版本串：
    // 版本升级后此断言自动跟随 `kAppVersion`。
    expect(kAppVersion, isNotEmpty);
    expect(find.text('版本 $kAppVersion'), findsOneWidget);
    expect(find.text('随手记 Sui'), findsOneWidget);
    // 只读呈现：对话框内不得有文本输入 / 开关等可写控件（AC-204）。
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('窄屏「更多」菜单可达关于，且为同一份版本呈现（AC-199）', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final controller = AppController(
      repository: NoteRepository(db, deviceId: 'fr56-test'),
      database: db,
    );
    await controller.bootstrap();

    await tester.binding.setSurfaceSize(const Size(500, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: const MaterialApp(home: NoteShell()),
      ),
    );
    await _settle(tester);

    // 窄屏不渲染桌面应用菜单栏；M19 起「关于」收口在底部「我的」页（ui-spec §31.4）。
    expect(find.byType(AppMenuBar), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile-tab-4')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // 「关于」在「我的」页末尾，长屏也需滚动到可见（ListView 懒构建）。
    await tester.scrollUntilVisible(
      find.text('关于'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pump();

    expect(find.text('关于'), findsOneWidget);
    await tester.tap(find.text('关于'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // M19：关于改为独立全屏面板，版本文案仍与桌面同一来源（BR-56.3）。
    expect(find.text('版本 $kAppVersion'), findsWidgets);
  });
}
