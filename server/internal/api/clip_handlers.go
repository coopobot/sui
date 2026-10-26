package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"sui/note-server/internal/clip"
	"sui/note-server/internal/store"
	"sui/note-server/internal/sync"
)

// 整页截图的体积闸门（v0.14.0）。
//
//   - maxScreenshotBytes：**解码后**字节上限 8 MiB（接口契约）。
//   - maxScreenshotBase64Chars：**载荷（base64 文本）**长度上限 = 6 MiB − 256 KiB。
//     依据是**请求体上限**（maxBodyBytes() 默认 8 MiB）：body 里还要装整页 HTML，给它留
//     256 KiB。超过它就直接忽略——绝不能等到 http.MaxBytesReader 触发 413，那会让
//     **整单剪藏失败**，而截图只是加成。
//
// 两者都只**忽略该字段**，绝不让剪藏本身失败。
const (
	maxScreenshotBytes       = 8 << 20
	maxScreenshotBase64Chars = 6<<20 - 256*1024
)

// handleClip 处理网页剪藏：接收 {url,title,html,mode?}，净化为 Markdown，
// 本地化页面图片（FR-38），并把正文 + 附件映射一并入库。
//
// v0.13.3（FR-34 修订）：**每次剪藏都新建一条笔记**——唯一性按本次生成的 `noteID`
// （`clip-` + 128 bit 随机），**不再按 URL 判重**：同一个 URL 多次剪藏的内容可能不同
// （页面已改版 / 换了 `mode` / 只想要其中一段），判重会把新内容覆盖到旧笔记上。
// `notes.source_url` 只作**来源标记**（溯源 + 「收件箱」判据），与 `mode` 无关（BR-37.5）。
func (s *Server) handleClip(w http.ResponseWriter, r *http.Request) {
	// M10：大请求体路由单独延长**读**期限（§8）；须在读 body 之前调用。
	extendReadDeadline(w)
	// v0.13.2（AC-268）：媒体本地化预算 30s > 全局 WriteTimeout 10s，**写**期限必须一并延长，
	// 否则「图多 / 图慢」时响应被写期限切断——笔记已落库、客户端却拿空响应（表现为剪藏失败）。
	extendWriteDeadline(w)
	var req struct {
		URL   string `json:"url"`
		Title string `json:"title"`
		HTML  string `json:"html"`
		Mode  string `json:"mode"`
		// Screenshot 是**可选**的整页截图（v0.14.0：扩展在全页快照模式下滚动拼接后上行）。
		// 缺失 / 解码失败 / 超限 / 非图片 → 忽略，行为与今天**完全一致**。
		Screenshot *screenshotPayload `json:"screenshot"`
	}
	// M10-T25：整包读入前先限长（超限 413）。
	body := http.MaxBytesReader(w, r.Body, maxBodyBytes())
	if err := json.NewDecoder(body).Decode(&req); err != nil {
		if isTooLarge(err) {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]any{"ok": false, "error": "payload too large"})
			return
		}
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	if req.URL == "" && req.HTML == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "url or html required"})
		return
	}
	// M10-T27：剪藏来源**只校验 scheme**——服务端从不向它发起请求，故不做地址拦截
	// （否则「剪藏内网页」会被整篇拒绝）；出网地址闸门在媒体本地化处（clip/guard.go）。
	if req.URL != "" {
		if err := clip.ValidateSourceURL(req.URL); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
			return
		}
	}

	// 净化 HTML → Markdown（按 mode 分支），并就地本地化页面图片。
	var (
		title, content, mode string
		webClipHTML          string
		assets               []clip.MediaAsset
		unlocalized          int
		purified             bool
	)
	if req.HTML != "" {
		result, err := clip.PurifyWithOptions(req.HTML, clip.Options{
			PageURL:     req.URL,
			Mode:        req.Mode,
			Blobs:       s.blobs,
			Client:      s.mediaClient, // nil → clip 包的带闸门默认客户端（M10-T27）
			CaptureHTML: clip.NormalizeMode(req.Mode) == clip.ModeSnapshot,
		})
		if err != nil {
			writeInternalError(w, r, err)
			return
		}
		title = result.Title
		content = result.Content
		mode = result.Mode
		webClipHTML = result.WebClipHTML
		assets = result.Assets
		unlocalized = result.SkippedImages
		purified = true
	}
	// 客户端传的标题优先
	if req.Title != "" {
		title = req.Title
	}
	if title == "" {
		title = "未命名剪藏"
	}

	// 正文开头附上来源链接。
	//
	// M10-T30：来源 URL 是外部输入，直接拼进 Markdown 会被 `]` / `)` 截断链接、
	// 把剩余内容漏成正文（甚至注入结构），故文本位与目标位分别转义。
	sourceLine := "> 来源：[" + clip.EscapeMarkdownText(req.URL) + "](" +
		clip.EscapeMarkdownURL(req.URL) + ")\n\n"
	fullContent := sourceLine + content

	// v0.13.3（FR-34 修订）：**不做任何判重**——id 每次新生成 128 bit 随机十六进制，
	// 于是「同一 URL 再剪一次」= 一条新笔记；旧笔记与其修订历史原样保留。
	token, err := store.NewToken()
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	noteID := "clip-" + token[:32]

	// M16 / FR-83：网页原件落库（内容寻址）并登记附件映射。
	// 放在截图之前：有原件时不再把截图追加到正文（截图仍作降级附件保留）。
	// 失败只降级（不写原件引用），不阻断剪藏。
	var webClipAsset *sync.AttachmentItem
	webClipRef := ""
	if purified && mode == "snapshot" && webClipHTML != "" {
		hash := store.HashBytes([]byte(webClipHTML))
		if _, err := s.blobs.Put(hash, bytes.NewReader([]byte(webClipHTML))); err == nil {
			webClipRef = "[网页原件](sui://webclip/" + hash + ")\n\n"
			webClipAsset = &sync.AttachmentItem{
				ID:         "att-" + store.HashBytes([]byte(noteID + "|webclip"))[:32],
				Filename:   "网页原件.html",
				MimeKind:   "webclip",
				ByteSize:   len(webClipHTML),
				SHA256:     hash,
				StorageRef: hash,
			}
			// 原件放正文最前，Markdown 正文仍在其后（可搜索 / 可编辑）。
			fullContent = webClipRef + fullContent
		} else {
			log.Printf("clip: webclip blob put failed note=%s: %v", noteID, err)
		}
	}

	// v0.14.0 / 整页截图：把可选截图落成**附件**并在正文末尾引用。
	//
	// 只在 `snapshot` 模式接受：用户显式选了「智能提取正文」，就不该在笔记末尾多出一张
	// 整页图；且扩展侧本来也只在快照模式采集（双保险）。`mode` 取净化结果——它与扩展
	// 传来的取值同义（未知值回落 article，BR-37.4）。
	//
	// 任何一步失败都**只丢弃截图**（不写 blob、不登记附件、不追加引用），笔记照常建立。
	var screenshotAsset *sync.AttachmentItem
	if req.Screenshot != nil && purified && mode == "snapshot" {
		if data, mimeOK := decodeScreenshot(req.Screenshot); mimeOK {
			hash := store.HashBytes(data)
			if _, err := s.blobs.Put(hash, bytes.NewReader(data)); err == nil {
				screenshotAsset = &sync.AttachmentItem{
					// 附件 id 沿用既有派生风格（笔记 id + 内容地址 → 截断 32 hex）：
					// 笔记 id 每条剪藏唯一 → 行唯一；字节仍按 sha256 内容寻址天然去重。
					ID:         "att-" + store.HashBytes([]byte(noteID + "|screenshot"))[:32],
					Filename:   screenshotFilename(req.Screenshot.Filename),
					MimeKind:   "image",
					ByteSize:   len(data),
					SHA256:     hash,
					StorageRef: hash,
				}
				// 引用只在**真正入库成功**后才追加到正文末尾。
				// M16 / FR-83：有网页原件时不再追加截图（原件才是主呈现），
				// 但截图仍作为附件保留，供 WebView 不可用时降级。
				if webClipRef == "" {
					fullContent += "\n\n---\n\n![整页截图](sui://" + hash + ")\n"
				}
			}
		}
	}

	// 组装附件映射（FR-38 / BR-38.2/38.3）：附件 id 由「笔记 id + 图片内容地址」派生。
	// 笔记 id 每条剪藏唯一 → 每条剪藏各自持有自己的附件行；**字节**仍按 sha256 内容寻址
	// 天然去重（同一张图在库里只存一份）。
	attachments := make([]sync.AttachmentItem, 0, len(assets)+1)
	for _, a := range assets {
		attachments = append(attachments, sync.AttachmentItem{
			ID:         "att-" + store.HashBytes([]byte(noteID + "|" + a.SHA256))[:32],
			Filename:   a.Filename,
			MimeKind:   a.MimeKind,
			ByteSize:   a.ByteSize,
			SHA256:     a.SHA256,
			StorageRef: a.SHA256,
		})
	}
	if screenshotAsset != nil {
		attachments = append(attachments, *screenshotAsset)
	}
	if webClipAsset != nil {
		attachments = append(attachments, *webClipAsset)
	}

	// M16 / FR-86：剪藏默认标签「网页剪藏」（幂等；失败只记录，不影响剪藏成功）。
	// 必须在 Push 之前拿到 tagID 并随 PushItem 一起提交，保证标签与笔记**同批**落库；
	// 否则客户端可能在 push 之后、SyncNoteTags 之前拉到笔记，之后增量 pull 不再包含它。
	var tagIDs []string
	if tagID, err := s.store.EnsureTag("网页剪藏"); err != nil {
		log.Printf("clip: ensure tag failed note=%s: %v", noteID, err)
	} else {
		tagIDs = []string{tagID}
	}

	// 通过 sync 协议写入：id 是本次新生成的 → 服务端基线必然是 0（`version` 恒为 1）。
	resp, err := s.sync.Push(sync.PushItem{
		ID:           noteID,
		Title:        title,
		Content:      fullContent,
		BaseVersion:  0,
		Version:      1,
		SourceDevice: "clip:web-extension",
		Attachments:  attachments,
		TagIDs:       &tagIDs,
	})
	if err != nil {
		writeInternalError(w, r, err)
		return
	}

	// 登记**来源标记**（不是幂等键，v0.13.3 / BR-34.3）：供溯源展示与客户端「收件箱」判据；
	// 普通笔记不写该列。同一 URL 对应多篇笔记是**正常**的。
	if req.URL != "" {
		if err := s.store.SetNoteSourceURL(noteID, req.URL); err != nil {
			writeInternalError(w, r, err)
			return
		}
	}

	// 发送变更通知（WebSocket）
	s.hub.NotifyChange()

	out := map[string]any{
		"ok":      true,
		"noteId":  noteID,
		"title":   title,
		"version": resp.AppliedVersion,
		"url":     req.URL,
	}
	if purified {
		// mode 供扩展回显；unlocalizedImages 供扩展提示「N 张图片未本地化」（BR-38.4 / §5）。
		out["mode"] = mode
		out["unlocalizedImages"] = unlocalized
	}
	writeJSON(w, http.StatusOK, out)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// screenshotPayload 是剪藏请求里的**可选**整页截图（v0.14.0）。
//
// 只承载展示名与 base64 字节：类型判定走内容（魔数），不信 filename 的扩展名——
// 展示名是客户端可控的自由文本，不能拿它当安全判据。
type screenshotPayload struct {
	Filename   string `json:"filename"`
	DataBase64 string `json:"dataBase64"`
}

// decodeScreenshot 解码并校验截图载荷。
//
// 返回 (字节, 是否为受支持的图片)。**任一环节不满足就返回 false**，调用方据此忽略该字段：
//   - 空载荷 / base64 非法（含非法字符、长度不合法）→ 忽略；
//   - 编码后超过 maxScreenshotBase64Chars，或解码后超过 maxScreenshotBytes → 忽略
//     （**不是**整单 400/413）；
//   - 解码后为空 → 忽略；
//   - 魔数不是 JPEG / PNG（含声明 .jpg 但内容是别的）→ 忽略。
//
// 先按 base64 文本长度粗筛，避免为一个明显超限的载荷做无谓的解码与内存分配。
func decodeScreenshot(p *screenshotPayload) ([]byte, bool) {
	if p == nil {
		return nil, false
	}
	if p.DataBase64 == "" || len(p.DataBase64) > maxScreenshotBase64Chars {
		return nil, false
	}
	// 容忍客户端插入的空白（换行 / 空格）：这不是「非法 base64」，只是排版。
	compact := strings.NewReplacer("\n", "", "\r", "", " ", "", "\t", "").Replace(p.DataBase64)
	data, err := base64.StdEncoding.DecodeString(compact)
	if err != nil || len(data) == 0 || int64(len(data)) > maxScreenshotBytes {
		return nil, false
	}
	return data, isSupportedImage(data)
}

// isSupportedImage 按**魔数**判定 jpeg / png（本功能只接受这两类）。
func isSupportedImage(data []byte) bool {
	if len(data) >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF {
		return true // JPEG：SOI 标记 FF D8，后接首个段标记 FF
	}
	pngMagic := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
	return bytes.HasPrefix(data, pngMagic)
}

// screenshotFilename 返回截图的展示名（空 / 全空白 → 缺省名）。
func screenshotFilename(name string) string {
	if trimmed := strings.TrimSpace(name); trimmed != "" {
		return trimmed
	}
	return "整页截图.jpg"
}
