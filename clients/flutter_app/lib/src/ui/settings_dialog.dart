import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_version.dart';
import '../platform/desktop_platform.dart';
import '../platform/storage_location.dart';
import 'app_controller.dart';
import 'appearance/font_availability.dart';
import 'appearance/font_catalog.dart';
import 'storage_settings.dart';
import 'sync_settings_dialog.dart';

/// 设置中心分区（M14 / FR-63 / ui-spec §24.1、详细设计 §3.3）。
enum SettingsSection {
  /// 外观：主题 + 字体（FR-64 / FR-65）。
  appearance,

  /// 同步与账号（原「同步设置」，FR-15 / FR-57）。
  sync,

  /// 本地存储（**仅桌面端**渲染，FR-58）。
  storage,

  /// 附件缓存上限（FR-15）。
  cache,

  /// 关于与版本（FR-56）。
  about,
}

/// 打开**设置中心**（M14 / FR-63）。
///
/// 桌面端由应用菜单栏「文件 → 设置…」与 `Ctrl/Cmd + ,` 触发；窄屏 / Web 由顶栏
/// 「更多 → 设置」触发；顶栏同步状态图标以 `section: SettingsSection.sync` 直达同步分区。
/// 三处**同源同效**（同一对话框、同一命令来源，BR-63.1 / AC-269~AC-271）。
Future<void> showSettingsDialog(
  BuildContext context,
  AppController controller, {
  SettingsSection section = SettingsSection.appearance,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider<AppController>.value(
      value: controller,
      child: SettingsDialog(initialSection: section),
    ),
  );
}

/// 设置中心对话框（五分区）。
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, this.initialSection = SettingsSection.appearance});

  final SettingsSection initialSection;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  /// 初始分区。**若请求的分区在当前端不可见**（例如移动端请求「本地存储」），
  /// 回落到第一个可见分区——不可见分区的内容**一律不得渲染**（BR-63.2 / AC-223 / AC-272）。
  late SettingsSection _section = _sections.contains(widget.initialSection)
      ? widget.initialSection
      : _sections.first;

  /// 分区清单：**「本地存储」仅桌面端**渲染（BR-63.2 / AC-272）。
  List<SettingsSection> get _sections => <SettingsSection>[
        SettingsSection.appearance,
        SettingsSection.sync,
        if (isDesktopPlatform && supportsStorageLocation) SettingsSection.storage,
        SettingsSection.cache,
        SettingsSection.about,
      ];

  static const Map<SettingsSection, (IconData, String)> _meta =
      <SettingsSection, (IconData, String)>{
    SettingsSection.appearance: (Icons.palette_outlined, '外观'),
    SettingsSection.sync: (Icons.cloud_outlined, '同步与账号'),
    SettingsSection.storage: (Icons.folder_outlined, '本地存储'),
    SettingsSection.cache: (Icons.sd_storage_outlined, '附件缓存'),
    SettingsSection.about: (Icons.info_outline, '关于'),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('设置'),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: 660,
        height: 470,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 520;
            final nav = _buildNav(narrow, theme);
            final body = Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _buildSection(_section),
              ),
            );
            return narrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      nav,
                      const Divider(height: 1),
                      const SizedBox(height: 12),
                      body,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 156, child: nav),
                      const VerticalDivider(width: 1),
                      body,
                    ],
                  );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildNav(bool narrow, ThemeData theme) {
    if (narrow) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            for (final section in _sections)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(_meta[section]!.$2),
                  selected: _section == section,
                  onSelected: (_) => setState(() => _section = section),
                ),
              ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final section in _sections)
          ListTile(
            dense: true,
            selected: _section == section,
            leading: Icon(_meta[section]!.$1, size: 20),
            title: Text(_meta[section]!.$2),
            onTap: () => setState(() => _section = section),
          ),
      ],
    );
  }

  Widget _buildSection(SettingsSection section) => switch (section) {
        SettingsSection.appearance => AppearanceSettingsSection(
            controller: context.read<AppController>(),
          ),
        SettingsSection.sync => const SyncSettingsPanel(),
        SettingsSection.storage =>
          StorageSettingsSection(controller: context.read<AppController>()),
        SettingsSection.cache => CacheSettingsSection(
            controller: context.read<AppController>(),
          ),
        SettingsSection.about => const AboutSettingsSection(),
      };
}

/// 「外观」分区：主题（FR-64）+ 字体（FR-65）。
///
/// [availability] 可注入（单测用假量测器），默认取进程内共享实例。
class AppearanceSettingsSection extends StatefulWidget {
  const AppearanceSettingsSection({
    super.key,
    required this.controller,
    this.availability,
    this.webDegraded,
  });

  final AppController controller;
  final FontAvailability? availability;

  /// 测试注入：覆盖 [kIsWeb] 判定（用于覆盖 Web 端字体降级路径，AC-292）。
  final bool? webDegraded;

  @override
  State<AppearanceSettingsSection> createState() =>
      _AppearanceSettingsSectionState();
}

class _AppearanceSettingsSectionState extends State<AppearanceSettingsSection> {
  late final FontAvailability _fonts =
      widget.availability ?? FontAvailability.instance;

  AppController get _c => widget.controller;

  /// Web 渲染器**拿不到宿主系统字体**（只认打包进资源的字体）→ 仅提供「跟随系统」
  /// 并给出原因说明，不静默隐藏（BR-65.6 / AC-292）。
  bool get _webDegraded => widget.webDegraded ?? kIsWeb;

  List<FontOption> get _uiOptions => _webDegraded
      ? const <FontOption>[kSystemFontOption]
      : _fonts.available(uiFontOptions(defaultTargetPlatform));

  List<FontOption> get _bodyOptions => _webDegraded
      ? const <FontOption>[kSystemFontOption]
      : _fonts.available(bodyFontOptions(defaultTargetPlatform));

  Future<void> _setThemeMode(ThemeMode mode) => _c.setThemeMode(mode);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('主题', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            SegmentedButton<ThemeMode>(
              segments: const <ButtonSegment<ThemeMode>>[
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto_outlined, size: 18),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.light,
                  label: Text('亮'),
                  icon: Icon(Icons.light_mode_outlined, size: 18),
                ),
                ButtonSegment<ThemeMode>(
                  value: ThemeMode.dark,
                  label: Text('暗'),
                  icon: Icon(Icons.dark_mode_outlined, size: 18),
                ),
              ],
              selected: <ThemeMode>{_c.themeMode},
              onSelectionChanged: (selection) =>
                  _setThemeMode(selection.first),
            ),
            const SizedBox(height: 4),
            Text(
              '默认「跟随系统」，随操作系统明暗即时切换；本机偏好，不随同步。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const Divider(height: 28),
            Text('字体', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            _fontDropdown(
              label: '界面字体',
              hint: '菜单 / 列表 / 工具栏 / 对话框',
              options: _uiOptions,
              current: _c.uiFontFamily,
              onChanged: _c.setUiFontFamily,
            ),
            const SizedBox(height: 12),
            _fontDropdown(
              label: '笔记正文字体',
              hint: '笔记标题与正文（格式 / 预览）；源码与代码块恒为等宽',
              options: _bodyOptions,
              current: _c.bodyFontFamily,
              onChanged: _c.setBodyFontFamily,
            ),
            if (!_fonts.isOptionUsable(_c.uiFontFamily) ||
                !_fonts.isOptionUsable(_c.bodyFontFamily)) ...[
              const SizedBox(height: 8),
              Text(
                '所选字体在当前设备不可用，已回退为「跟随系统」（重新装回该字体即恢复）。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              _webDegraded
                  ? 'Web 端不支持自选系统字体：浏览器渲染器不提供宿主系统字体，仅支持「跟随系统」。'
                  : '只列出本机实际可用的系统字体（探测不到的不显示）；本机偏好，不随同步下发。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const Divider(height: 28),
            Text('笔记本默认字体', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '「笔记正文字体」是全局默认；单个笔记本可在左栏的笔记本菜单里'
              '「默认字体…」单独覆盖（可选「跟随全局默认」清除覆盖）。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        );
      },
    );
  }

  Widget _fontDropdown({
    required String label,
    required String hint,
    required List<FontOption> options,
    required String? current,
    required Future<void> Function(String?) onChanged,
  }) {
    // 当前值不可用（换机 / 卸载）时，下拉仍要能显示它 → 临时并入一项并标注。
    final value = fontValueOfFamily(current);
    final items = <DropdownMenuItem<String>>[
      for (final option in options)
        DropdownMenuItem<String>(
          value: fontValueOfFamily(option.family),
          child: Text(option.label),
        ),
    ];
    if (!items.any((item) => item.value == value)) {
      items.add(
        DropdownMenuItem<String>(
          value: value,
          child: Text('$current（不可用，已回退）'),
        ),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: hint,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: items,
      onChanged: (selected) => onChanged(fontFamilyOfValue(selected)),
    );
  }
}

/// 「附件缓存」分区：占用 / 上限（原「同步设置」内的缓存控件，M14 独立成区）。
class CacheSettingsSection extends StatefulWidget {
  const CacheSettingsSection({super.key, required this.controller});

  final AppController controller;

  @override
  State<CacheSettingsSection> createState() => _CacheSettingsSectionState();
}

class _CacheSettingsSectionState extends State<CacheSettingsSection> {
  late final TextEditingController _cacheMb = TextEditingController(
    text: '${widget.controller.cacheLimitBytes ~/ (1024 * 1024)}',
  );

  int _usedBytes = 0;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _loadUsage();
  }

  @override
  void dispose() {
    _cacheMb.dispose();
    super.dispose();
  }

  Future<void> _loadUsage() async {
    final (used, _) = await widget.controller.attachmentCacheUsage();
    if (!mounted) return;
    setState(() => _usedBytes = used);
  }

  Future<void> _save() async {
    final mb = int.tryParse(_cacheMb.text.trim());
    if (mb == null || mb <= 0) {
      setState(() {
        _message = '缓存上限需为正整数（单位 MB）';
        _messageIsError = true;
      });
      return;
    }
    await widget.controller.setCacheLimitBytes(mb * 1024 * 1024);
    if (!mounted) return;
    setState(() {
      _message = '缓存上限已设为 $mb MB（下次连接生效）';
      _messageIsError = false;
    });
    await _loadUsage();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('附件缓存', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(
          '附件按需下载并受上限约束（本机记账，不随同步）。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 12),
        Text(
          '当前占用：${_fmtBytes(_usedBytes)} / ${_fmtBytes(widget.controller.cacheLimitBytes)}',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(
              width: 140,
              child: TextField(
                controller: _cacheMb,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '上限 (MB)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: _save, child: const Text('保存上限')),
          ],
        ),
        if (_message != null) ...[
          const SizedBox(height: 10),
          Text(
            _message!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _messageIsError
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }
}

/// 「关于」分区（FR-56 / ADR-020）：版本号取构建期常量，离线可见。
class AboutSettingsSection extends StatelessWidget {
  const AboutSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('关于随手记 Sui', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text('版本 $kAppVersion', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        Text(
          '自托管 · 离线优先 · 多端同步的 Markdown 笔记应用。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 12),
        const SelectableText(
          '使用文档：https://coopobot.github.io/sui/',
        ),
      ],
    );
  }
}

/// 笔记本「默认字体…」对话框（M14 / FR-66 / ui-spec §24.4 / AC-295）。
///
/// 为该笔记本**覆盖**笔记正文字体，或选「跟随全局默认」清除覆盖；
/// 覆盖值只影响本机呈现（键 `ui.notebookFont.<notebookId>`），不进同步（BR-66.3）。
Future<void> showNotebookFontDialog(
  BuildContext context,
  AppController controller,
  String notebookId,
  String notebookName,
) {
  final fonts = FontAvailability.instance;
  final options = kIsWeb
      ? const <FontOption>[kSystemFontOption]
      : fonts.available(bodyFontOptions(defaultTargetPlatform));
  final current = controller.notebookFontFamily(notebookId);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('「$notebookName」的默认字体'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                dense: true,
                title: const Text('跟随全局默认'),
                subtitle: const Text('清除本笔记本的字体覆盖'),
                trailing:
                    current == null ? const Icon(Icons.check, size: 18) : null,
                onTap: () async {
                  await controller.setNotebookFontFamily(notebookId, null);
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
              ),
              for (final option in options)
                if (option.family != null)
                  ListTile(
                    dense: true,
                    title: Text(option.label),
                    trailing: current == option.family
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () async {
                      await controller.setNotebookFontFamily(
                          notebookId, option.family);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
