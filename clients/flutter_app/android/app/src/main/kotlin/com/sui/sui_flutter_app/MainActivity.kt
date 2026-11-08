package com.sui.sui_flutter_app

import android.content.ActivityNotFoundException
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 自研平台通道 `sui/platform`（FR-70 / FR-71 / FR-110 / ADR-028 / ADR-040）——
 * 只承载 Flutter 内建能力覆盖不到的三件事，均为十几行原生代码，不引入任何第三方插件：
 *
 * - `openUrl`：用系统浏览器打开网址（`ACTION_VIEW`）。Android 没有 POSIX 壳层，
 *   桌面端那套 `cmd /c start` / `open` / `xdg-open` 在 Android 上不可用；
 * - `clipboardHtml`：读剪贴板的 HTML 表示（`ClipData.Item.getHtmlText()`）。Flutter 内建
 *   `Clipboard.getData('text/html')` 在 Android 嵌入层只实现 `text/plain`，拿不到富文本，
 *   于是「粘贴保留原格式」会静默失效；
 * - `openFile`：用系统默认应用打开附件（`FileProvider` content URI + `ACTION_VIEW`）。
 *   发起方与接收方是**不同应用**，API 24+ 不允许传 `file://`（`FileUriExposedException`），
 *   故必须经 `FileProvider` 转成 `content://` 并**只读、一次性**授权。
 *
 * 通道只回**原始字符串 / 布尔 / 返回码**：CF_HTML 解析、HTML→Markdown 转换、MIME 判定
 * 全在 Dart 侧，便于单测与跨平台复用。
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> result.success(openUrl(call.argument<String>("url")))
                    "clipboardHtml" -> result.success(readClipboardHtml())
                    "openFile" -> result.success(
                        openFile(
                            call.argument<String>("path"),
                            call.argument<String>("mime")
                        )
                    )
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

    /**
     * 用系统默认应用打开 [path] 指向的附件，返回**返回码**（Dart 侧据此分流提示文案）：
     *
     * - `ok`：已交给系统（已拉起默认应用或弹出应用选择器）；
     * - `nohandler`：本机没有能处理该 MIME 的应用（`ActivityNotFoundException`）；
     * - `error`：文件不存在 / 授权配置异常等其它失败。
     *
     * MIME 为空时退化为通配 MIME（[WILDCARD_MIME]）：系统仍会弹选择器让用户自己挑，
     * 比「什么都打不开」好（BR-110.3，Dart 侧 `mimeTypeFor` 已经兜了这一层，这里再兜
     * 一次防御）。
     *
     * 注：通配 MIME 的字面量留在代码常量里，**不写进注释**——Kotlin 的块注释允许嵌套，
     * 注释里出现「星号紧接斜杠」会把后面的源码一起吞成注释（首版即踩此坑）。
     */
    private fun openFile(path: String?, mime: String?): String {
        if (path.isNullOrBlank()) return CODE_ERROR
        return try {
            val file = File(path)
            if (!file.exists()) return CODE_ERROR
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val type = if (mime.isNullOrBlank()) WILDCARD_MIME else mime
            startActivity(
                Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, type)
                    // 只读、一次性授权：接收方可读，但**不能**写回（ADR-040 决策 2）。
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            CODE_OK
        } catch (e: ActivityNotFoundException) {
            CODE_NO_HANDLER
        } catch (e: Exception) {
            CODE_ERROR
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
        private const val WILDCARD_MIME = "*/*"
        private const val CODE_OK = "ok"
        private const val CODE_NO_HANDLER = "nohandler"
        private const val CODE_ERROR = "error"
    }
}
