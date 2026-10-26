/// 本地存储设置区与「存储目录不可用」阻断屏（M12 修订 / FR-58）。
///
/// 产品规格见 [ui-spec.md] §22.2、流程见 [user-flows.md] §17.3；
/// 详细设计见 `technology/design/low-level-design/local-storage.md`；决策见 ADR-022。
///
/// 三件事在此落地：
/// 1. **呈现**：当前数据目录 + 占用（库 / 附件）+「打开所在文件夹」（AC-216）；
/// 2. **迁移**：选目录 → 前置校验（同路径 / 已含数据 / 非空确认）→ 确认 → 进度 → 结果；
///    成功后提示**重启生效**并说明旧目录已保留（AC-217 / AC-219 / AC-220）；
/// 3. **阻断**：指针目录不可用时整屏阻断，给「重试 / 改回默认目录 / 重新指定路径」三选一，
///    **绝不静默回落**（AC-222 / BR-58.7）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/directory_picker.dart';
import '../platform/storage_location.dart';
import 'app_controller.dart';

/// 字节数可读化（占用显示用）。
String _fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// 迁移阶段 → 界面文案。
String storageStageText(StorageMigrationStage stage) {
  switch (stage) {
    case StorageMigrationStage.checkpoint:
      return '正在落盘待写数据…';
    case StorageMigrationStage.copyDatabase:
      return '正在复制数据库…';
    case StorageMigrationStage.copyBlobs:
      return '正在复制附件…';
    case StorageMigrationStage.verify:
      return '正在校验…';
    case StorageMigrationStage.switchPointer:
      return '正在切换存储位置…';
  }
}

/// 「迁移完成 / 存储位置已变更」后的重启提示（迁移后**重启生效**，ADR-022 决策 7）。
Future<void> showStorageRestartDialog(
  BuildContext context, {
  required String title,
  required String body,
}) async {
  final restart = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('稍后手动重启'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('立即重启'),
        ),
      ],
    ),
  );
  if (restart == true) {
    await quitApp();
  }
}

/// 「本地存储」设置区：嵌在「同步设置」对话框内（桌面端）。
class StorageSettingsSection extends StatefulWidget {
  const StorageSettingsSection({super.key, required this.controller});

  final AppController controller;

  @override
  State<StorageSettingsSection> createState() => _StorageSettingsSectionState();
}

class _StorageSettingsSectionState extends State<StorageSettingsSection> {
  bool _busy = false;
  bool _isError = false;
  String? _message;
  StorageMigrationStage? _stage;
  ({int databaseBytes, int blobBytes})? _usage;

  AppController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _loadUsage();
  }

  Future<void> _loadUsage() async {
    final dir = _c.dataDir;
    if (dir == null) return;
    final usage = await storageUsage(dir);
    if (!mounted) return;
    setState(() => _usage = usage);
  }

  void _report(String message, {required bool isError}) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _stage = null;
      _message = message;
      _isError = isError;
    });
  }

  Future<bool?> _confirm(String title, String body, {String okText = '继续'}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(okText),
          ),
        ],
      ),
    );
  }

  Future<void> _changeLocation() async {
    final current = _c.dataDir;
    if (current == null) return;

    final target = await pickDirectoryDialog(dialogTitle: '选择新的存储位置');
    if (target == null || !mounted) return;

    setState(() {
      _busy = true;
      _message = null;
      _stage = null;
      _isError = false;
    });

    // 前置校验（BR-58.5 / AC-220）：同路径与「已含本应用数据」直接拒绝。
    final issue = await checkStorageTarget(
      currentDir: current,
      targetDir: target,
    );
    if (issue == StorageTargetIssue.samePath) {
      _report('目标目录与当前存储位置相同，无需迁移。', isError: true);
      return;
    }
    if (issue == StorageTargetIssue.containsAppData) {
      _report(
        '目标目录已包含随手记 Sui 的数据，已拒绝覆盖（请选择空目录或其它位置）。',
        isError: true,
      );
      return;
    }
    if (issue == StorageTargetIssue.notEmpty) {
      final ok = await _confirm(
        '目标目录非空',
        '目标目录中已有其它文件。\n\n'
            '迁移不会删除这些文件；但若存在同名文件（如 `sui.sqlite`）会导致迁移失败。\n\n'
            '是否继续？',
      );
      if (ok != true) {
        setState(() => _busy = false);
        return;
      }
      if (!mounted) return;
    }

    final usage = _usage;
    final confirmed = await _confirm(
      '更改存储位置',
      '将把本地库与附件缓存迁移到：\n$target\n\n'
          '当前占用：库 ${_fmtBytes(usage?.databaseBytes ?? 0)} · '
          '附件 ${_fmtBytes(usage?.blobBytes ?? 0)}\n\n'
          '迁移期间请勿退出应用；校验通过后需**重新启动应用**才会使用新位置。\n'
          '旧位置的数据会**保留**，确认无误后可自行删除。',
      okText: '开始迁移',
    );
    if (confirmed != true) {
      setState(() => _busy = false);
      return;
    }

    // 先把各视图编辑器尚未落库的防抖内容写入本地库，再进入维护态迁移（BR-58.3 / §4）。
    await _c.flushEditors();
    final result = await _c.migrateStorageTo(
      target,
      onStage: (stage) {
        if (mounted) setState(() => _stage = stage);
      },
    );
    if (!mounted) return;

    if (result.ok) {
      setState(() {
        _busy = false;
        _stage = null;
        _message = '迁移完成：$target（重启后生效，旧数据保留在 $current）';
        _isError = false;
      });
      await _loadUsage();
      if (!mounted) return;
      await showStorageRestartDialog(
        context,
        title: '迁移完成',
        body: '数据已迁移到：\n$target\n\n'
            '旧数据已保留在：\n$current\n\n'
            '重新启动应用后生效。',
      );
    } else {
      _report('迁移失败：${result.error}（当前仍使用 $current）', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dir = _c.dataDir;
    final usage = _usage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 28),
        Text('本地存储', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        SelectableText(
          dir ?? '（未知目录）',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          '占用：库 ${_fmtBytes(usage?.databaseBytes ?? 0)} · '
          '附件 ${_fmtBytes(usage?.blobBytes ?? 0)}',
          style: theme.textTheme.labelMedium,
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _changeLocation,
              icon: const Icon(Icons.drive_file_move_outlined, size: 18),
              label: const Text('更改位置…'),
            ),
            TextButton.icon(
              onPressed:
                  (dir == null || _busy) ? null : () => openInFileManager(dir),
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: const Text('打开所在文件夹'),
            ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Text(
            _stage == null ? '正在准备…' : storageStageText(_stage!),
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 10),
          Text(
            _message!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: _isError ? theme.colorScheme.error : theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }
}

/// 存储目录不可用时的**整屏阻断**界面（BR-58.7 / AC-222）。
///
/// 应用此时运行在占位目录上：在用户做出选择前**不读写用户数据**；
/// 三个动作都以「写入指针 + 重启生效」结束（不做热切换，ADR-022 决策 7）。
class StorageUnavailableScreen extends StatefulWidget {
  const StorageUnavailableScreen({super.key});

  @override
  State<StorageUnavailableScreen> createState() =>
      _StorageUnavailableScreenState();
}

class _StorageUnavailableScreenState extends State<StorageUnavailableScreen> {
  bool _busy = false;
  String? _message;

  Future<void> _retry() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final res = await resolveStorageLocation();
    if (!mounted) return;
    setState(() => _busy = false);
    if (res.usable) {
      await showStorageRestartDialog(
        context,
        title: '存储目录已恢复',
        body: '目录已可访问：\n${res.dataDir}\n\n重新启动应用后生效。',
      );
    } else {
      setState(() => _message = '目录仍不可用：${res.configuredDir ?? res.dataDir}');
    }
  }

  Future<void> _useDefaultDir() async {
    final res = context.read<AppController>().storageResolution;
    if (res == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    await writeStoragePointer(res.pointerPath, res.defaultDir);
    if (!mounted) return;
    setState(() => _busy = false);
    await showStorageRestartDialog(
      context,
      title: '已改回默认目录',
      body: '将使用默认目录：\n${res.defaultDir}\n\n'
          '原目录（${res.configuredDir ?? ''}）的数据**不会被删除**。\n\n'
          '重新启动应用后生效。',
    );
  }

  Future<void> _pickOtherDir() async {
    final res = context.read<AppController>().storageResolution;
    if (res == null) return;
    final target = await pickDirectoryDialog(dialogTitle: '选择数据目录');
    if (target == null || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    await writeStoragePointer(res.pointerPath, target);
    if (!mounted) return;
    setState(() => _busy = false);
    await showStorageRestartDialog(
      context,
      title: '已指定新的数据目录',
      body: '将使用：\n$target\n\n重新启动应用后生效。',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final res = context.watch<AppController>().storageResolution;
    final dir = res?.configuredDir ?? res?.dataDir ?? '(未知)';
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('数据目录不可用', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Text(
                    '应用当前指向的数据目录无法访问：\n$dir\n\n'
                    '常见原因：外置盘 / 网络盘未挂载、目录被移动或删除、权限不足。\n\n'
                    '为避免误以为「数据丢失」，应用**不会**自动改用其它目录。请选择：',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '未做出选择前，应用不会读写你的笔记数据。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : _retry,
                        child: const Text('重试'),
                      ),
                      OutlinedButton(
                        onPressed: _busy ? null : _useDefaultDir,
                        child: const Text('改回默认目录'),
                      ),
                      OutlinedButton(
                        onPressed: _busy ? null : _pickOtherDir,
                        child: const Text('重新指定其他路径'),
                      ),
                    ],
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _message!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
