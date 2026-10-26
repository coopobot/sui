import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_core/note_core.dart';
import 'package:provider/provider.dart';

import 'package:sui_flutter_app/src/ui/app_controller.dart';
import 'package:sui_flutter_app/src/ui/appearance/app_palette.dart';
import 'package:sui_flutter_app/src/ui/appearance/font_availability.dart';
import 'package:sui_flutter_app/src/ui/markdown_editing_controller.dart';
import 'package:sui_flutter_app/src/ui/markdown_editor.dart';
import 'package:sui_flutter_app/src/ui/settings_dialog.dart';

/// 有界推进：**禁用** `pumpAndSettle()`（30s 周期同步定时器 + 不定长进度指示会永久排帧，
/// 见 Agents.md §5.2）。
Future<void> _settle(WidgetTester tester,
    {Duration step = const Duration(milliseconds: 16), int frames = 30}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

AppController _newController(AppDatabase db) => AppController(
      repository: NoteRepository(db, deviceId: 'm14-test'),
      database: db,
    );

int _ch(double v) => (v * 255).round();

/// 「中性」判据（BR-67.2）：分量差 ≤ 2。
bool _isNeutral(Color c) {
  final r = _ch(c.r), g = _ch(c.g), b = _ch(c.b);
  return (r - g).abs() <= 2 && (g - b).abs() <= 2 && (r - b).abs() <= 2;
}

/// 「黄色系」判据（BR-68.1）：R > G > B 且 R ≥ 240。
bool _isYellow(Color c) =>
    _ch(c.r) > _ch(c.g) && _ch(c.g) > _ch(c.b) && _ch(c.r) >= 240;

double _luminance(Color c) {
  double lin(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double _contrast(Color a, Color b) {
  final l1 = _luminance(a), l2 = _luminance(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

/// 当前树里所有 `Container` 的显式底色（用于取色断言）。
List<Color?> _containerColors(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .map((c) => c.color)
    .toList();

bool _hasBackground(InlineSpan span, Color color) {
  if (span.style?.backgroundColor == color) return true;
  if (span is TextSpan) {
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (_hasBackground(child, color)) return true;
    }
  }
  return false;
}

Widget _dialogHost(
  AppController controller, {
  SettingsSection section = SettingsSection.appearance,
}) {
  return ChangeNotifierProvider<AppController>.value(
    value: controller,
    child: MaterialApp(
      theme: buildSuiTheme(brightness: Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () =>
                  showSettingsDialog(context, controller, section: section),
              child: const Text('打开设置'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('中性色板与主题（FR-64 / FR-67 / AC-301~AC-306）', () {
    test('亮色：编辑区纯白，结构块一律中性灰，且与底色可分辨', () {
      const p = AppPalette.light;
      expect(p.surface, const Color(0xFFFFFFFF), reason: 'AC-301：编辑区纯白（守 FR-28）');
      for (final color in <Color>[
        p.containerLowest,
        p.containerLow,
        p.container,
        p.containerHigh,
        p.containerHighest,
        p.codeSurface,
        p.codeBorder,
        p.chipSurface,
        p.chipBorder,
        p.selectedSurface,
        p.divider,
        p.outline,
        p.outlineVariant,
      ]) {
        expect(_isNeutral(color), isTrue, reason: 'AC-302~304：$color 必须中性（无绿调）');
      }
      final ratio = (_luminance(p.surface) + 0.05) / (_luminance(p.container) + 0.05);
      expect(ratio, greaterThanOrEqualTo(1.03), reason: 'BR-67.2：块边界须可分辨');
      // 高亮为黄色系（AC-307 判据：R > G > B 且 R ≥ 240）。
      expect(_isYellow(p.highlight), isTrue);
    });

    test('暗色：大面积底色中性（无绿调），高亮为暗黄且文字可读', () {
      const p = AppPalette.dark;
      for (final color in <Color>[
        p.surface,
        p.containerLow,
        p.container,
        p.containerHigh,
        p.containerHighest,
        p.codeSurface,
        p.codeBorder,
        p.chipSurface,
        p.chipBorder,
        p.selectedSurface,
      ]) {
        expect(_isNeutral(color), isTrue, reason: 'BR-67.4：$color 必须中性');
      }
      expect(_luminance(p.surface), lessThan(0.06), reason: '暗色底应足够暗');
      // 暗色高亮：暗黄系 + 与浅色文字对比度 ≥ 4.5:1（AC-309）。
      expect(_ch(p.highlight.r) > _ch(p.highlight.g), isTrue);
      expect(_ch(p.highlight.g) > _ch(p.highlight.b), isTrue);
      expect(_contrast(p.highlight, const Color(0xFFE6E6E6)), greaterThanOrEqualTo(4.5));
    });

    test('主题：surface / scaffold / 选中态去绿，品牌主色保留（AC-306）', () {
      final light = buildSuiTheme(brightness: Brightness.light);
      expect(light.colorScheme.surface, const Color(0xFFFFFFFF));
      expect(light.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
      expect(light.colorScheme.surfaceContainerHighest,
          AppPalette.light.containerHighest);
      expect(light.listTileTheme.selectedTileColor,
          AppPalette.light.selectedSurface);
      // 品牌绿仍在（强调语义）：G 通道显著高于 R。
      expect(_ch(light.colorScheme.primary.g) > _ch(light.colorScheme.primary.r), isTrue);

      final dark = buildSuiTheme(brightness: Brightness.dark);
      expect(dark.colorScheme.surface, AppPalette.dark.surface);
      expect(dark.colorScheme.surfaceContainerHighest,
          AppPalette.dark.containerHighest);
      expect(_ch(dark.colorScheme.primary.g) > _ch(dark.colorScheme.primary.r), isTrue);
    });

    testWidgets('编辑区容器底色：亮 = 纯白（AC-301）', (tester) async {
      final controller = MarkdownEditingController(text: '正文一行');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: buildSuiTheme(brightness: Brightness.light),
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: MarkdownEditor(
              controller: controller,
              mode: EditorMode.formatted,
              onChanged: () {},
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(_containerColors(tester), contains(const Color(0xFFFFFFFF)),
          reason: '亮色下编辑区容器底色应为纯白');
    });

    testWidgets('编辑区容器底色：暗 = 中性深灰（AC-278）', (tester) async {
      final controller = MarkdownEditingController(text: '正文一行');
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(
        theme: buildSuiTheme(brightness: Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: MarkdownEditor(
              controller: controller,
              mode: EditorMode.formatted,
              onChanged: () {},
            ),
          ),
        ),
      ));
      await tester.pump();
      final colors = _containerColors(tester);
      expect(colors, contains(AppPalette.dark.surface));
      expect(colors, isNot(contains(const Color(0xFFFFFFFF))),
          reason: '暗色下不得残留白底（AC-278）');
    });

    testWidgets('格式模式：==高亮== 底色为黄色系（AC-307）', (tester) async {
      late BuildContext ctx;
      final controller = MarkdownEditingController(text: '==关键==');
      await tester.pumpWidget(MaterialApp(
        theme: buildSuiTheme(brightness: Brightness.light),
        home: Builder(builder: (context) {
          ctx = context;
          return Scaffold(
            body: SizedBox(
              height: 200,
              child: MarkdownEditor(
                controller: controller,
                mode: EditorMode.formatted,
                onChanged: () {},
              ),
            ),
          );
        }),
      ));
      await tester.pump();
      // 格式模式的正文样式由控制器自身产出（`buildTextSpan`），直接取来断言。
      final span = controller.buildTextSpan(
        context: ctx,
        style: const TextStyle(fontSize: 15),
        withComposing: true,
      );
      expect(_hasBackground(span, AppPalette.light.highlight), isTrue,
          reason: '格式模式 ==高亮== 底色应为黄色系');
      controller.dispose();
    });

    testWidgets('预览模式：高亮与格式模式同色系（AC-308）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildSuiTheme(brightness: Brightness.light),
        home: const Scaffold(body: MarkdownPreview(text: '==关键==')),
      ));
      await tester.pump();
      // 预览态默认 `selectable: true`：flutter_markdown 用 `SelectableText` 而非
      // `RichText` 承载行内 span，两处都要取（与 M5/M9 测试同款处理）。
      final spans = <InlineSpan>[
        ...tester.widgetList<RichText>(find.byType(RichText)).map((rt) => rt.text),
        ...tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((st) => st.textSpan ?? const TextSpan()),
      ];
      final found =
          spans.any((s) => _hasBackground(s, AppPalette.light.highlight));
      expect(found, isTrue, reason: '预览态高亮应取黄色系（不再是 tertiaryContainer 浅青）');
    });
  });

  group('主题与字体偏好（FR-64 / FR-65 / FR-66 / AC-275~AC-300）', () {
    late AppDatabase db;
    late AppController controller;

    setUp(() async {
      db = AppDatabase.memory();
      controller = _newController(db);
      await controller.bootstrap();
    });

    tearDown(() async {
      controller.dispose();
      await db.close();
    });

    test('默认值：主题跟随系统、两项字体跟随系统（AC-275 / AC-290）', () {
      expect(controller.themeMode, ThemeMode.system);
      expect(controller.uiFontFamily, isNull);
      expect(controller.bodyFontFamily, isNull);
    });

    test('置位并落盘：重载控制器后保留（AC-280 / AC-291）', () async {
      await controller.setThemeMode(ThemeMode.dark);
      await controller.setUiFontFamily('Microsoft YaHei');
      await controller.setBodyFontFamily('SimSun');

      final reloaded = _newController(db);
      await reloaded.bootstrap();
      expect(reloaded.themeMode, ThemeMode.dark);
      expect(reloaded.uiFontFamily, 'Microsoft YaHei');
      expect(reloaded.bodyFontFamily, 'SimSun');
      reloaded.dispose();
    });

    test('非法主题值回落「跟随系统」（BR-64.1）', () async {
      await controller.settings.set('ui.themeMode', 'purple');
      final reloaded = _newController(db);
      await reloaded.bootstrap();
      expect(reloaded.themeMode, ThemeMode.system);
      reloaded.dispose();
    });

    test('字体偏好只落本地 settings，且「system」等价于跟随系统（BR-65.7）', () async {
      await controller.setBodyFontFamily('KaiTi');
      expect(await controller.settings.get('ui.fontFamily.body'), 'KaiTi');
      await controller.setBodyFontFamily(null);
      expect(await controller.settings.get('ui.fontFamily.body'), 'system');
      expect(controller.bodyFontFamily, isNull);
    });

    test('笔记本覆盖：继承 / 覆盖 / 清除 + 有效字体（AC-296 / AC-295）', () async {
      await controller.setBodyFontFamily('SimSun');
      expect(controller.effectiveBodyFontFamily('nb-1'), 'SimSun');

      await controller.setNotebookFontFamily('nb-1', 'KaiTi');
      expect(controller.notebookFontFamily('nb-1'), 'KaiTi');
      expect(controller.effectiveBodyFontFamily('nb-1'), 'KaiTi');
      expect(controller.effectiveBodyFontFamily('nb-2'), 'SimSun',
          reason: '覆盖只影响该笔记本（BR-66.2）');
      expect(await controller.settings.get('ui.notebookFont.nb-1'), 'KaiTi');

      await controller.setNotebookFontFamily('nb-1', null);
      expect(controller.notebookFontFamily('nb-1'), isNull);
      expect(controller.effectiveBodyFontFamily('nb-1'), 'SimSun');
      expect(await controller.settings.get('ui.notebookFont.nb-1'), isNull,
          reason: '「跟随全局默认」应删除该键');
    });

    test('删除笔记本时清理字体覆盖键（AC-299 / BR-66.4）', () async {
      await controller.createNotebook('工作');
      final id = controller.notebooks.first.id;
      await controller.setNotebookFontFamily(id, 'SimSun');
      expect(await controller.settings.get('ui.notebookFont.$id'), 'SimSun');

      await controller.deleteNotebook(id);
      expect(controller.notebookFontFamily(id), isNull);
      expect(await controller.settings.get('ui.notebookFont.$id'), isNull);
    });
  });

  group('设置中心（FR-63 / AC-269~AC-274）', () {
    late AppDatabase db;
    late AppController controller;

    setUp(() async {
      db = AppDatabase.memory();
      controller = _newController(db);
      await controller.bootstrap();
    });

    tearDown(() async {
      controller.dispose();
      await db.close();
    });

    testWidgets('桌面端：五分区齐全、标题为「设置」、可切换分区', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.binding.setSurfaceSize(const Size(1200, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_dialogHost(controller));
        await tester.tap(find.text('打开设置'));
        await _settle(tester);

        expect(find.text('设置'), findsOneWidget);
        for (final label in <String>[
          '外观',
          '同步与账号',
          '本地存储',
          '附件缓存',
          '关于',
        ]) {
          expect(find.text(label), findsWidgets, reason: '分区「$label」应可达');
        }
        // 默认停在「外观」分区：主题三态可见。
        expect(find.text('跟随系统'), findsWidgets);
        expect(find.text('亮'), findsOneWidget);
        expect(find.text('暗'), findsOneWidget);

        // 切到「关于」：版本呈现（FR-56 / AC-273）。
        await tester.tap(find.text('关于').first);
        await _settle(tester);
        expect(find.textContaining('版本'), findsWidgets);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('桌面端：同步图标直达「同步与账号」，既有能力不丢（AC-271 / AC-273）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _dialogHost(controller, section: SettingsSection.sync),
      );
      await tester.tap(find.text('打开设置'));
      await _settle(tester);

      expect(find.text('服务端地址'), findsOneWidget);
      expect(find.text('注册并连接'), findsOneWidget);
      expect(find.text('登录并连接'), findsOneWidget);
      expect(find.text('本机设备 ID'), findsOneWidget);
    });

    testWidgets('移动端：不渲染「本地存储」分区（BR-63.2 / AC-272）', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.binding.setSurfaceSize(const Size(600, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_dialogHost(controller));
        await tester.tap(find.text('打开设置'));
        await _settle(tester);

        expect(find.text('外观'), findsWidgets);
        expect(find.text('本地存储'), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('主题三态切换即时生效（AC-274 / BR-63.4）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_dialogHost(controller));
      await tester.tap(find.text('打开设置'));
      await _settle(tester);

      await tester.tap(find.text('暗'));
      await _settle(tester);
      expect(controller.themeMode, ThemeMode.dark);

      await tester.tap(find.text('亮'));
      await _settle(tester);
      expect(controller.themeMode, ThemeMode.light);
    });
  });

  group('外观分区：字体（FR-65 / AC-284~AC-294）', () {
    late AppDatabase db;
    late AppController controller;

    setUp(() async {
      db = AppDatabase.memory();
      controller = _newController(db);
      await controller.bootstrap();
    });

    tearDown(() async {
      controller.dispose();
      await db.close();
    });

    Widget host(FontAvailability fonts, {bool? webDegraded}) =>
        ChangeNotifierProvider<AppController>.value(
          value: controller,
          child: MaterialApp(
            theme: buildSuiTheme(brightness: Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: AppearanceSettingsSection(
                  controller: controller,
                  availability: fonts,
                  webDegraded: webDegraded,
                ),
              ),
            ),
          ),
        );

    testWidgets('两项独立：界面字体与笔记正文字体各一个选择器（AC-284）',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        // 只让「宋体」可解析（其余落回哨兵度量 → 不列出，AC-288）。
        final fonts = FontAvailability(
          measurer: (family, sample) => family == 'SimSun' ? 90 : 50,
        );
        await tester.binding.setSurfaceSize(const Size(700, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(host(fonts));
        await tester.pump();

        expect(find.text('界面字体'), findsOneWidget);
        expect(find.text('笔记正文字体'), findsOneWidget);
        expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));

        // 打开「界面字体」下拉：可选项 = 跟随系统 + 宋体（其余探测不可用 → 不列出）。
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await _settle(tester);
        expect(find.text('宋体（SimSun）'), findsWidgets);
        expect(find.textContaining('微软雅黑'), findsNothing,
            reason: '探测不可用的字体不得列出（否则「选了没反应」）');

        await tester.tap(find.text('宋体（SimSun）').last);
        await _settle(tester);
        expect(controller.uiFontFamily, 'SimSun');
        expect(controller.bodyFontFamily, isNull,
            reason: '两项互不覆盖（BR-65.1）');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Web 端降级：仅「跟随系统」并给出原因（AC-292 / BR-65.6）',
        (tester) async {
      final fonts = FontAvailability(measurer: (family, sample) => 50);
      await tester.binding.setSurfaceSize(const Size(700, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(host(fonts, webDegraded: true));
      await tester.pump();

      expect(find.textContaining('Web 端不支持自选系统字体'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await _settle(tester);
      expect(find.textContaining('跟随系统'), findsWidgets);
    });

    testWidgets('偏好不可用时标注「不可用，已回退」（AC-293）', (tester) async {
      await controller.setUiFontFamily('GhostFont');
      final fonts = FontAvailability(
        measurer: (family, sample) => family == 'SimSun' ? 90 : 50,
      );
      await tester.binding.setSurfaceSize(const Size(700, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(host(fonts));
      await tester.pump();

      expect(find.textContaining('不可用'), findsWidgets);
      expect(find.textContaining('已回退'), findsWidgets);
    });

    testWidgets('笔记本「默认字体…」对话框：覆盖与清除（AC-295）', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final previous = FontAvailability.instance;
      FontAvailability.instanceForTesting =
          FontAvailability(measurer: (family, sample) => family == 'SimSun' ? 90 : 50);
      try {
        await controller.createNotebook('工作');
        final id = controller.notebooks.first.id;
        await tester.binding.setSurfaceSize(const Size(900, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ChangeNotifierProvider<AppController>.value(
            value: controller,
            child: MaterialApp(
              theme: buildSuiTheme(brightness: Brightness.light),
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => showNotebookFontDialog(
                          context, controller, id, '工作'),
                      child: const Text('默认字体…'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('默认字体…'));
        await _settle(tester);

        expect(find.text('「工作」的默认字体'), findsOneWidget);
        expect(find.text('跟随全局默认'), findsOneWidget);

        await tester.tap(find.text('宋体（SimSun）'));
        await _settle(tester);
        expect(controller.notebookFontFamily(id), 'SimSun');
      } finally {
        FontAvailability.instanceForTesting = previous;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
