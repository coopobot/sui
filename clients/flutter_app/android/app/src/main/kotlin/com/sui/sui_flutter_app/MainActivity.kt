package com.sui.sui_flutter_app

import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 自研平台通道 `sui/platform`（FR-70 / FR-71 / ADR-028）——只承载 Flutter 内建能力
 * 覆盖不到的两件事，均为十几行原生代码，不引入任何第三方插件：
 *
 * - `openUrl`：用系统浏览器打开网址（`ACTION_VIEW`）。Android 没有 POSIX 壳层，
 *   桌面端那套 `cmd /c start` / `open` / `xdg-open` 在 Android 上不可用；
 * - `clipboardHtml`：读剪贴板的 HTML 表示（`ClipData.Item.getHtmlText()`）。Flutter 内建
 *   `Clipboard.getData('text/html')` 在 Android 嵌入层只实现 `text/plain`，拿不到富文本，
 *   于是「粘贴保留原格式」会静默失效。
 *
 * 通道只回**原始字符串 / 布尔**：CF_HTML 之类的解析与 HTML→Markdown 转换全在 Dart 侧，
 * 便于单测与跨平台复用。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                    "clipboardHtml" -> result.success(readClipboardHtml())
                    else -> result.notImplemented()
                }
            }
    }

    /** 用系统默认浏览器打开 [url]；无可用 Activity 时返回 false（不抛异常）。 */
    private fun openUrl(url: String?): Boolean {
        if (url.isNullOrBlank()) return false
        return try {
            startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 读剪贴板的 HTML 表示；没有富文本表示时返回 null（Dart 侧回落纯文本）。 */
    private fun readClipboardHtml(): String? {
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return null
        val clip = manager.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).htmlText
    }

    companion object {
        private const val CHANNEL = "sui/platform"
    }
}
