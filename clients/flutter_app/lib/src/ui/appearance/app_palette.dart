import 'package:flutter/material.dart';

/// 品牌种子色（M2 / FR-28 起沿用）。
///
/// M14 **不改品牌体系**：`primary` / `secondary` / `tertiary` 仍由它派生，
/// 只把**中性角色**（`surface*` / `outline*`）覆盖为中性灰阶（ADR-027 决策 1 / 方案 D 已否决）。
const Color kBrandSeed = Color(0xFF2E8B57);

/// 左侧栏（笔记本树）深色导航底色：**亮 / 暗两模式都保持深色**（FR-64 / ui-spec §13）。
const Color kSidebarBg = Color(0xFF222226);

/// 中性色板（M14 / FR-67）。
///
/// **判据**（`appearance-settings.md` §7.5）：每个值都必须是中性的——R = G = B，或分量差 ≤ 2；
/// 结构块与编辑区底色之间保留亮度差（≥ 1.03），使「块」的边界可见（不是把所有块涂白）。
@immutable
class AppPalette {
  const AppPalette({
    required this.surface,
    required this.containerLowest,
    required this.containerLow,
    required this.container,
    required this.containerHigh,
    required this.containerHighest,
    required this.codeSurface,
    required this.codeBorder,
    required this.chipSurface,
    required this.chipBorder,
    required this.selectedSurface,
    required this.divider,
    required this.outline,
    required this.outlineVariant,
    required this.highlight,
  });

  /// 编辑区 / 正文底。**亮色 = 纯白**（守 FR-28）。
  final Color surface;

  /// `surfaceContainerLowest`：与编辑区同色的「最低层」。
  final Color containerLowest;

  /// `surfaceContainerLow`。
  final Color containerLow;

  /// `surfaceContainer`：结构块（格式工具栏 / 单元格 / 面板）。
  final Color container;

  /// `surfaceContainerHigh`：对话框 / 浮层底。
  final Color containerHigh;

  /// `surfaceContainerHighest`：表格表头 / 强结构块 / 附件单元底。
  final Color containerHighest;

  /// 代码块底（与结构块区分）。
  final Color codeSurface;

  /// 代码块边框。
  final Color codeBorder;

  /// 附件卡片底。
  final Color chipSurface;

  /// 附件卡片边框。
  final Color chipBorder;

  /// 列表项选中态底（M3 默认取 `primary` 低透明 → 带绿调，M14 显式改中性）。
  final Color selectedSurface;

  /// 分隔线。
  final Color divider;

  /// 描边（强）。
  final Color outline;

  /// 描边（弱）。
  final Color outlineVariant;

  /// `==高亮==` 底色（FR-68：黄色系，不再是 `tertiaryContainer` 的浅青）。
  final Color highlight;

  /// 亮色板：编辑区纯白 + 中性灰阶（全部 R = G = B）。
  static const AppPalette light = AppPalette(
    surface: Color(0xFFFFFFFF),
    containerLowest: Color(0xFFFFFFFF),
    containerLow: Color(0xFFF8F8F8),
    container: Color(0xFFF3F3F3),
    containerHigh: Color(0xFFEFEFEF),
    containerHighest: Color(0xFFEAEAEA),
    codeSurface: Color(0xFFF6F6F6),
    codeBorder: Color(0xFFE0E0E0),
    chipSurface: Color(0xFFEFEFEF),
    chipBorder: Color(0xFFD8D8D8),
    selectedSurface: Color(0xFFEFEFEF),
    divider: Color(0xFFE0E0E0),
    outline: Color(0xFF8A8A8A),
    outlineVariant: Color(0xFFDCDCDC),
    highlight: Color(0xFFFFF3A3),
  );

  /// 暗色板：**不取种子的暗色方案**（实测 `surface` 为 `#0F1511`、`surfaceContainerHighest`
  /// 为 `#313631`，都带绿调），改为显式中性深灰（ADR-027 决策 4）。
  static const AppPalette dark = AppPalette(
    surface: Color(0xFF141414),
    containerLowest: Color(0xFF141414),
    containerLow: Color(0xFF1A1A1A),
    container: Color(0xFF1F1F1F),
    containerHigh: Color(0xFF242424),
    containerHighest: Color(0xFF292929),
    codeSurface: Color(0xFF1B1B1B),
    codeBorder: Color(0xFF333333),
    chipSurface: Color(0xFF242424),
    chipBorder: Color(0xFF3A3A3A),
    selectedSurface: Color(0xFF262626),
    divider: Color(0xFF333333),
    outline: Color(0xFF9A9A9A),
    outlineVariant: Color(0xFF3A3A3A),
    highlight: Color(0xFF4E4400),
  );

  static AppPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// 外观扩展：把**中性色板**与**笔记正文字体**随主题下发（M14 / ADR-026 / ADR-027）。
///
/// 编辑器等呈现层经 [SuiAppearance.of] 取用，**无需**依赖 `AppController`
/// （保持「呈现层不反向依赖状态层」的既有分层，也与 widget 测试的解耦口径一致）。
@immutable
class SuiAppearance extends ThemeExtension<SuiAppearance> {
  const SuiAppearance({required this.palette, this.bodyFontFamily});

  /// 中性色板。
  final AppPalette palette;

  /// **笔记正文字体**族名；`null` = 跟随系统（FR-65）。
  ///
  /// 只作用于「笔记标题 + 格式模式正文 + 预览模式正文」；源码模式与代码块恒等宽（BR-65.2）。
  final String? bodyFontFamily;

  static SuiAppearance of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SuiAppearance>() ??
        SuiAppearance(palette: AppPalette.of(theme.brightness));
  }

  /// 把笔记正文字体套到给定样式上（`null` 时原样返回 = 跟随系统）。
  TextStyle applyBodyFont(TextStyle style) => bodyFontFamily == null
      ? style
      : style.copyWith(fontFamily: bodyFontFamily);

  @override
  SuiAppearance copyWith({AppPalette? palette, String? bodyFontFamily}) =>
      SuiAppearance(
        palette: palette ?? this.palette,
        bodyFontFamily: bodyFontFamily ?? this.bodyFontFamily,
      );

  /// 主题切换动画期间的插值：色板按亮度二选一即可（无中间态需求），字体取目标值。
  @override
  SuiAppearance lerp(ThemeExtension<SuiAppearance>? other, double t) {
    if (other is! SuiAppearance) return this;
    return t < 0.5 ? this : other;
  }
}

/// 构建 Sui 主题（M14 / FR-64 / FR-67）。
///
/// * [brightness]：亮 / 暗（由 `themeMode` + 平台亮度在 `MaterialApp` 侧决定）；
/// * [uiFontFamily]：**界面字体**（`null` = 跟随系统）；
/// * [bodyFontFamily]：**笔记正文字体**（`null` = 跟随系统），随 [SuiAppearance] 下发。
ThemeData buildSuiTheme({
  required Brightness brightness,
  String? uiFontFamily,
  String? bodyFontFamily,
}) {
  final palette = AppPalette.of(brightness);
  final base = ColorScheme.fromSeed(
    seedColor: kBrandSeed,
    brightness: brightness,
  );

  // 主题层「中性角色覆盖」：`surface*` / `outline*` 一律取中性灰阶。
  // 这族角色被**弹窗 / 面板 / 表格 / 单元格 / 代码块 / 附件卡片**共同消费，
  // 一次覆盖即**全局去绿**（ADR-027 决策 1 / appearance-settings.md §4.3）。
  // 品牌强调色（primary / secondary / tertiary / *Container）**保持不动**。
  final scheme = base.copyWith(
    surface: palette.surface,
    surfaceContainerLowest: palette.containerLowest,
    surfaceContainerLow: palette.containerLow,
    surfaceContainer: palette.container,
    surfaceContainerHigh: palette.containerHigh,
    surfaceContainerHighest: palette.containerHighest,
    outline: palette.outline,
    outlineVariant: palette.outlineVariant,
  );

  final theme = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // 亮色下即纯白（守 FR-28）；暗色下为中性深灰（无绿调）。
    scaffoldBackgroundColor: palette.surface,
    fontFamily: uiFontFamily,
    extensions: <ThemeExtension<dynamic>>[
      SuiAppearance(palette: palette, bodyFontFamily: bodyFontFamily),
    ],
  );

  return theme.copyWith(
    // 列表项选中态：M3 默认取 `primary` 低透明（带绿调）→ M14 显式改中性灰（FR-67 / AC-304）。
    // 选中**文字 / 图标**仍取品牌色（小面积强调，BR-67.5）。
    listTileTheme: theme.listTileTheme.copyWith(
      selectedTileColor: palette.selectedSurface,
      selectedColor: scheme.primary,
    ),
    dividerTheme: theme.dividerTheme.copyWith(color: palette.divider),
  );
}
