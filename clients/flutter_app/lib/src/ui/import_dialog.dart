import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:note_core/note_core.dart';

import '../platform/import_picker.dart';
import 'app_controller.dart';

/// 「导入文件…」入口的**统一实现**（M13 / FR-60 / ui-spec §23）。
///
/// 桌面「文件 → 导入文件…」（含 `Ctrl+Shift+I` 菜单加速键）与窄屏移动端 / Web
/// 顶栏「更多 → 导入文件…」都走这里，保证**同源同效**（AC-233）。
///
/// 本函数只做「预检 + 弹窗」；真正的转换与落库在
/// [AppController.importSourceFiles]（`note_core` 的 `FileImportService`）。
Future<void> showImportDialog(
  BuildContext context,
  AppController controller,
) async {
  // BR-60.2：目标笔记本已加密且未解锁 → 直接拒绝，连选择器都不打开。
  final reason = await controller.importTargetBlockReason();
  if (reason != null) {
    if (context.mounted) _snack(context, reason);
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _ImportDialog(controller: controller),
  );
}

/// 导入对话框（ui-spec §23.2 / §23.3）：**只读**目标笔记本 + 选择 + 进度 + 取消。
class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.controller});

  final AppController controller;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  bool _running = false;
  bool _cancelRequested = false;
  ImportProgress? _progress;

  /// 开始导入一批（[folder] 为真走「选择文件夹」）。
  ///
  /// 目标笔记本在**本次调用开始时**取值并全程冻结（BR-60.1）：控制器内部读的是
  /// 当前的 `selectedNotebookId`，导入期间用户改选左栏**不影响**落点。
  Future<void> _pick({required bool folder}) async {
    final files = folder ? await pickImportFolder() : await pickImportFiles();
    // 用户取消 / 没选到可导入的文件：保持对话框原状，不报错（ui-spec §23.2）。
    if (!mounted || files.isEmpty) return;

    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = ImportProgress(
        processed: 0,
        total: files.length,
        currentName: '',
      );
    });

    final ImportReport report;
    try {
      report = await widget.controller.importSourceFiles(
        files,
        isCancelled: () => _cancelRequested,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _running = false);
      _snack(context, '导入失败：$e');
      return;
    }
    if (!mounted) return;
    setState(() => _running = false);
    // 报告另开一个对话框：先关本框，避免对话框叠加。
    Navigator.of(context).pop();
    if (!context.mounted) return;
    await showImportReportDialog(context, widget.controller, report);
  }

  @override
  Widget build(BuildContext context) {
    final total = _progress?.total ?? 0;
    final processed = _progress?.processed ?? 0;
    return AlertDialog(
      title: const Text('导入文件'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 目标笔记本**只读**（BR-60.1 / AC-235）。
            Text('导入到：${widget.controller.importTargetLabel}'),
            if (widget.controller.importTargetNotebookId == null)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '如需导入到某个笔记本，请先在左栏选中它',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              '支持 .md / .markdown / .txt / .html / .htm；图片与附件会一并导入',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
            if (_running) ...[
              LinearProgressIndicator(
                value: total == 0 ? null : processed / total,
              ),
              const SizedBox(height: 8),
              Text('已处理 $processed / 共 $total'),
              if (_cancelRequested)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('正在停止…', style: TextStyle(fontSize: 12)),
                ),
            ],
          ],
        ),
      ),
      actions: _running
          ? [
              TextButton(
                onPressed: _cancelRequested
                    ? null
                    : () => setState(() => _cancelRequested = true),
                child: const Text('取消'),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              // Web 端不渲染文件夹入口（AC-234）。
              if (importFolderPickSupported)
                OutlinedButton(
                  onPressed: () => _pick(folder: true),
                  child: const Text('选择文件夹…'),
                ),
              FilledButton(
                onPressed: () => _pick(folder: false),
                child: const Text('选择文件…'),
              ),
            ],
    );
  }
}

/// 结果报告对话框（ui-spec §23.4）：汇总（四类计数分列）+ 逐项明细 + 复制报告。
Future<void> showImportReportDialog(
  BuildContext context,
  AppController controller,
  ImportReport report,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(report.cancelled ? '导入已取消' : '导入完成'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('导入到：${controller.importTargetLabel}'),
            const SizedBox(height: 6),
            Text(
              '成功 ${report.successCount} · 跳过 ${report.skippedCount} · '
              '失败 ${report.failedCount} · 未本地化资源 ${report.unlocalizedCount}',
            ),
            if (report.cancelled)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '已处理的笔记已保留；重新选择同一批文件可继续导入',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            if (report.items.isNotEmpty) const Divider(height: 20),
            if (report.items.isNotEmpty)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: report.items.length,
                  itemBuilder: (_, i) => _reportTile(report.items[i]),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            // BR-62.4：报告文本**不含**笔记正文。
            await Clipboard.setData(
              ClipboardData(text: report.toClipboardText()),
            );
            if (dialogContext.mounted) {
              _snack(dialogContext, '导入报告已复制到剪贴板');
            }
          },
          child: const Text('复制报告'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 一条明细：标题行 = 结果与（成功时的）笔记标题，副标题 = 文件名与资源计数。
Widget _reportTile(ImportItemResult item) {
  final (label, primary) = switch (item.outcome) {
    ImportOutcome.success => (
        '成功',
        item.title.isEmpty ? item.fileName : item.title,
      ),
    ImportOutcome.skipped => (
        '跳过·${_skipLabel(item.skipReason)}',
        item.fileName,
      ),
    ImportOutcome.failed => ('失败', '${item.fileName}：${item.failureReason}'),
  };
  final details = <String>[
    item.fileName,
    if (item.localizedResources > 0) '资源本地化 ${item.localizedResources}',
    if (item.unlocalizedResources > 0) '未本地化 ${item.unlocalizedResources}',
    if (item.warning.isNotEmpty) item.warning,
  ];
  return ListTile(
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(primary, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      details.join(' · '),
      style: const TextStyle(fontSize: 12),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: Text(label, style: const TextStyle(fontSize: 12)),
  );
}

/// 跳过原因的中文标签（BR-62.3：跳过与失败分开，且原因可读）。
String _skipLabel(ImportSkipReason? reason) => switch (reason) {
      ImportSkipReason.duplicate => '重复',
      ImportSkipReason.unsupportedType => '不支持的类型',
      ImportSkipReason.empty => '空文件',
      ImportSkipReason.tooLarge => '超出单文件上限',
      ImportSkipReason.batchLimit => '超出单批上限',
      ImportSkipReason.indexPage => '索引页',
      null => '已跳过',
    };

void _snack(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(SnackBar(content: Text(message)));
}
