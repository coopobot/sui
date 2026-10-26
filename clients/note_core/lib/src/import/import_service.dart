import 'dart:convert';
import 'dart:typed_data';

import '../blob/blob_store.dart';
import '../crypto/notebook_crypto.dart';
import '../models/attachment.dart';
import '../repository/note_repository.dart';
import '../util/ids.dart';
import '../util/mime_kind.dart';
import 'html_to_markdown.dart';
import 'import_types.dart';
import 'source_document.dart';
import 'text_decoding.dart';

/// M13（FR-60 / FR-61 / FR-62）—— 批量导入编排。
///
/// 详细设计 §7\~§9。职责：
/// * **目标可导入性预检**（[checkTarget]）：未解锁的加密笔记本**拒绝**导入（BR-60.2）；
/// * 逐文件：扩展名过滤 → 限额 → 解码（可能降级）→ 转换（可能多篇）→ 逐篇
///   指纹去重（BR-62.1）→ 资源本地化（§7）→ 单事务落库（BR-60.6）；
/// * 进度（按文件计）/ 取消（文件之间生效，AC-238）/ 结果报告（BR-62.3 / BR-62.4）。
///
/// **纯 Dart**：所有文件读取都经 [ImportSourceFile] 的字节与 [ResourceResolver]
/// 回调注入，本文件不 import `dart:io` / `dart:html` / Flutter（BR-60.9）。
class FileImportService {
  FileImportService({
    required this.repository,
    required this.blobStore,
    this.options = const ImportOptions(),
  });

  final NoteRepository repository;
  final BlobStore blobStore;
  final ImportOptions options;

  /// 目标可导入性预检：`null` = 可导入；否则返回**面向用户**的拒绝原因。
  ///
  /// BR-60.2：加密且未解锁的笔记本**不得**把明文写进去（守 BR-51.5），
  /// 故在进入文件选择**之前**就拒绝（零写入）。笔记本不存在或被软删除同样拒绝。
  Future<String?> checkTarget(String? notebookId) async {
    if (notebookId == null || notebookId.isEmpty) return null; // 未分组：始终可导入
    final nb = await repository.getNotebook(notebookId);
    if (nb == null || nb.isDeleted) {
      return '目标笔记本不存在（可能已被删除），请重新选择后再导入。';
    }
    if (nb.encrypted && !repository.isNotebookUnlocked(notebookId)) {
      return '目标笔记本「${nb.name}」已加密且未解锁，请先解锁后再导入。';
    }
    return null;
  }

  /// 执行一次导入；可对同一批文件重复调用以「续跑」，幂等由指纹保证（FR-62）。
  Future<ImportReport> run(
    List<ImportSourceFile> files, {
    required String? notebookId,
    bool Function()? isCancelled,
    void Function(ImportProgress progress)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    final items = <ImportItemResult>[];
    var cancelled = false;

    // §8：指纹集合在**开始时一次载入**（避免逐篇查询），并随导入过程追加
    // → 同批内相同内容也只导入第一篇（AC-252）。
    final fingerprints = await repository.listImportFingerprints();

    for (var i = 0; i < files.length; i++) {
      // §9：取消**仅在文件之间**生效。
      if (isCancelled != null && isCancelled()) {
        cancelled = true;
        break;
      }
      final file = files[i];
      if (i >= options.maxFiles) {
        items.add(ImportItemResult(
          fileName: file.name,
          outcome: ImportOutcome.skipped,
          skipReason: ImportSkipReason.batchLimit,
        ));
        onProgress?.call(ImportProgress(
            processed: i + 1, total: files.length, currentName: file.name));
        continue;
      }
      items.addAll(await _importFile(file, notebookId, fingerprints));
      onProgress?.call(ImportProgress(
          processed: i + 1, total: files.length, currentName: file.name));
    }

    return ImportReport(
      items: items,
      cancelled: cancelled,
      startedAt: startedAt,
      finishedAt: DateTime.now(),
      targetNotebookLabel: await _targetLabel(notebookId),
    );
  }

  Future<String> _targetLabel(String? notebookId) async {
    if (notebookId == null || notebookId.isEmpty) return '未分组';
    final nb = await repository.getNotebook(notebookId);
    return nb?.name ?? '未分组';
  }

  // -------------------------------------------------------------------------
  // 单文件
  // -------------------------------------------------------------------------

  Future<List<ImportItemResult>> _importFile(
    ImportSourceFile file,
    String? notebookId,
    Set<String> fingerprints,
  ) async {
    // ① 扩展名过滤（§4.1）：在读取 / 转换字节**之前**判断，避免无谓开销。
    if (!isSupportedImportFileName(file.name)) {
      return [
        ImportItemResult(
          fileName: file.name,
          outcome: ImportOutcome.skipped,
          skipReason: ImportSkipReason.unsupportedType,
        ),
      ];
    }
    // ② 单文件限额（BR-60.3）。
    if (file.bytes.length > options.maxFileBytes) {
      return [
        ImportItemResult(
          fileName: file.name,
          outcome: ImportOutcome.skipped,
          skipReason: ImportSkipReason.tooLarge,
        ),
      ];
    }

    final ext = extensionOf(file.name);
    final List<ImportedDocument> documents;
    try {
      // ③ 解码 + ④ 转换（可能判为索引页 / 多节拆分为多篇）。
      if (ext == 'html' || ext == 'htm') {
        final result = convertHtmlDocument(file.bytes, file.name);
        if (result.indexPageReason != null) {
          return [
            ImportItemResult(
              fileName: file.name,
              outcome: ImportOutcome.skipped,
              skipReason: ImportSkipReason.indexPage,
            ),
          ];
        }
        documents = result.documents;
      } else if (ext == 'md' || ext == 'markdown') {
        final decoded = decodeTextBytes(file.bytes);
        documents = [
          parseMarkdownSource(decoded.text, file.name,
              degraded: decoded.degraded),
        ];
      } else {
        final decoded = decodeTextBytes(file.bytes);
        documents = [
          parsePlainTextSource(decoded.text, file.name,
              degraded: decoded.degraded),
        ];
      }
    } catch (e) {
      return [
        ImportItemResult(
          fileName: file.name,
          outcome: ImportOutcome.failed,
          failureReason: '转换失败：$e',
        ),
      ];
    }

    final results = <ImportItemResult>[];
    for (final doc in documents) {
      results.add(await _persist(
        file: file,
        document: doc,
        notebookId: notebookId,
        fingerprints: fingerprints,
      ));
    }
    if (results.isEmpty) {
      // 转换器明确判定「无可导入内容」（既无标题也无正文）→ 空文件（BR-60.4）。
      results.add(ImportItemResult(
        fileName: file.name,
        outcome: ImportOutcome.skipped,
        skipReason: ImportSkipReason.empty,
      ));
    }
    return results;
  }

  /// ⑤ 逐篇：指纹去重 → 资源本地化 → 单事务落库（§8 / §7 / BR-60.6）。
  Future<ImportItemResult> _persist({
    required ImportSourceFile file,
    required ImportedDocument document,
    required String? notebookId,
    required Set<String> fingerprints,
  }) async {
    final title = document.title.trim();
    final warning =
        document.warnings.isEmpty ? '' : document.warnings.first;

    // BR-60.4：转换后**标题与正文皆空** → 不落库。
    // 注意：文本链路的标题来自**文件名**，故判定必须同时看正文是否为空
    // （空文件 / 全空白文件 → 正文为空 → empty；而只有内容的文件不受影响）。
    if (document.markdown.trim().isEmpty) {
      return ImportItemResult(
        fileName: file.name,
        title: title,
        outcome: ImportOutcome.skipped,
        skipReason: ImportSkipReason.empty,
        warning: warning,
      );
    }

    // BR-62.1 / BR-62.2：指纹用**转换后**的 Markdown 正本；同批内也去重。
    final fingerprint = fingerprintFor(title, document.markdown);
    if (fingerprints.contains(fingerprint)) {
      return ImportItemResult(
        fileName: file.name,
        title: title,
        outcome: ImportOutcome.skipped,
        skipReason: ImportSkipReason.duplicate,
        warning: warning,
      );
    }

    final localized = await _localize(document, file);
    final now = DateTime.now();
    try {
      final note = await repository.createNoteWithAttachments(
        notebookId: notebookId,
        title: title,
        contentMarkdown: localized.markdown,
        attachments: localized.attachments,
        importFingerprint: fingerprint,
        now: now,
      );
      fingerprints.add(fingerprint);
      return ImportItemResult(
        fileName: file.name,
        title: title,
        outcome: ImportOutcome.success,
        noteId: note.id,
        localizedResources: localized.localized,
        unlocalizedResources: localized.unlocalized,
        warning: warning,
      );
    } on NotebookDecryptException catch (e) {
      // §9 / AC-240：导入途中被自动回锁 → 该篇 failed，其余继续。
      return ImportItemResult(
        fileName: file.name,
        title: title,
        outcome: ImportOutcome.failed,
        failureReason: '目标笔记本已锁定（${e.message}）',
        warning: warning,
      );
    } catch (e) {
      // BR-60.6：事务已回滚，不留半篇；原因必须**可行动**（BR-62.3）。
      return ImportItemResult(
        fileName: file.name,
        title: title,
        outcome: ImportOutcome.failed,
        failureReason: '写入本地库失败：$e',
        warning: warning,
      );
    }
  }

  // -------------------------------------------------------------------------
  // 资源本地化（§7）
  // -------------------------------------------------------------------------

  /// 资源替换的**最大趟数**（见 [_localize]：嵌套资源的占位符可能在外层被替换时才进入正文）。
  static const int _maxLocalizePasses = 8;

  Future<_LocalizedDocument> _localize(
    ImportedDocument document,
    ImportSourceFile file,
  ) async {
    var markdown = document.markdown;
    final attachments = <PendingAttachment>[];
    final seenSha = <String>{};
    var localized = 0;
    var unlocalized = 0;

    // 只处理**正文里真正出现**的引用。转换器把「链接包图片」折叠成单条外层引用后（见
    // `_renderAnchor` / `_labelWithoutPlaceholders`），内层图片不再出现在正文里——若仍为它取字节、
    // 落盘、建映射，就会给笔记挂上**没人引用的附件**，并把「本地化资源数」虚报高。
    final referenced = <int>{
      for (final ref in document.resources)
        if (markdown.contains(resourcePlaceholder(ref.index))) ref.index,
    };

    // 第一遍：**算出**每个资源的替换文本（取字节 / 落盘 / 降级），先不改正文。
    final replacements = <int, String>{};
    for (final ref in document.resources) {
      if (!referenced.contains(ref.index)) continue;
      final label = ref.alt.isNotEmpty ? ref.alt : ref.suggestedName;

      // (a) 远端 / 带 scheme：保持原 URL，**不下载**（FR-61 / AC-247）。
      if (ref.remote) {
        replacements[ref.index] = _renderRef(ref, ref.reference);
        continue;
      }

      Uint8List? bytes = ref.inlineBytes;
      // (b) 相对路径（含 `file:`）：经 [ResourceResolver] 取字节；Web 端恒为 null。
      if (bytes == null) {
        final resolve = file.resolveResource;
        if (resolve != null) {
          try {
            bytes = await resolve(ref.reference);
          } catch (_) {
            bytes = null;
          }
        }
      }
      // 超限资源按「取不到」处理（BR-60.3 / §7 第 1 条）。
      if (bytes != null && bytes.length > options.maxFileBytes) bytes = null;

      if (bytes == null || bytes.isEmpty) {
        // 降级形态：image → 仅 alt（空则用 suggestedName）；link → 仅链接文字。
        replacements[ref.index] = _degraded(ref, label);
        unlocalized++;
        continue;
      }

      final sha = sha256Hex(bytes);
      try {
        await blobStore.put(sha256: sha, bytes: bytes);
      } catch (_) {
        // §7 第 2 条：落盘异常（磁盘满等）→ **该资源降级**，不使整篇失败。
        replacements[ref.index] = _degraded(ref, label);
        unlocalized++;
        continue;
      }
      // BR-61.4：同一批内多篇引用同一图片只存一份；映射按篇逐条递增 refcount，
      // 篇内同一 sha256 只建一条映射（避免自增引用计数）。
      if (seenSha.add(sha)) {
        attachments.add(PendingAttachment(
          filename: ref.suggestedName.isEmpty ? 'resource' : ref.suggestedName,
          sha256: sha,
          byteSize: bytes.length,
          mimeKind: mimeKindFor(ref.suggestedName),
        ));
      }
      replacements[ref.index] = _renderRef(ref, 'sui://$sha');
      localized++;
    }

    // 第二遍：**替换到不动点**。必须多趟的原因：`<a href="…"><img src="…"></a>` 这类嵌套资源，
    // 外层链接的链接文字里**携带内层图片的占位符**（见 `_renderAnchor`），而它是在「外层链接被
    // 替换」那一刻才进入正文的——只跑一趟会残留内层占位符。真实数据实测（2026-10-12，29 篇印象
    // 笔记导出）有 5 篇命中；release 下断言不生效，占位符会被 `_stripResidualPlaceholders` 整段删掉
    // → **链接里嵌的图片/图标静默丢失**。多趟替换后嵌套资源自然组合成 `[![alt](sui://…)](href)`。
    for (var pass = 0; pass < _maxLocalizePasses; pass++) {
      var changed = false;
      for (final entry in replacements.entries) {
        final token = resourcePlaceholder(entry.key);
        if (!markdown.contains(token)) continue;
        markdown = markdown.replaceAll(token, entry.value);
        changed = true;
      }
      if (!changed) break;
    }

    // §7 收尾：**残留占位符是缺陷**。此处显式断言（release 下也清理，宁可不留噪声）。
    assert(
      !markdown.contains(kResourcePlaceholderStart),
      '资源本地化后不应残留占位符',
    );
    if (markdown.contains(kResourcePlaceholderStart)) {
      markdown = _stripResidualPlaceholders(markdown);
    }

    return _LocalizedDocument(
      markdown: markdown,
      attachments: attachments,
      localized: localized,
      unlocalized: unlocalized,
    );
  }

  static String _renderRef(ImportResourceRef ref, String url) {
    if (ref.kind == ImportResourceKind.image) {
      final size = ref.width == null ? '' : '{width=${ref.width}}';
      return '![${ref.alt}]($url)$size';
    }
    return '[${ref.alt.isEmpty ? ref.suggestedName : ref.alt}]($url)';
  }

  static String _degraded(ImportResourceRef ref, String label) =>
      ref.kind == ImportResourceKind.image ? label : label;

  static String _stripResidualPlaceholders(String markdown) => markdown
      .replaceAll(RegExp('$kResourcePlaceholderStart\\d*$kResourcePlaceholderEnd'), '')
      .replaceAll(kResourcePlaceholderStart, '')
      .replaceAll(kResourcePlaceholderEnd, '');
}

class _LocalizedDocument {
  const _LocalizedDocument({
    required this.markdown,
    required this.attachments,
    required this.localized,
    required this.unlocalized,
  });

  final String markdown;
  final List<PendingAttachment> attachments;
  final int localized;
  final int unlocalized;
}

/// 导入内容指纹（BR-62.1）：`sha256(title + "\n" + contentMarkdown)`，
/// 用**转换后**的 Markdown 正本（复用 `util/ids.dart` 的既有 `sha256Hex`）。
String fingerprintFor(String title, String markdown) =>
    sha256Hex(utf8.encode('$title\n$markdown'));
