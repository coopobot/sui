package api

import (
	"encoding/json"
	"net/http"

	"sui/note-server/internal/clip"
	"sui/note-server/internal/store"
	"sui/note-server/internal/sync"
)

// handleClip 处理网页剪藏：接收 {url,title,html,mode?}，净化为 Markdown，
// 本地化页面图片（FR-38），并把正文 + 附件映射一并入库。
//
// 幂等键为 notes.source_url（M4/BR-34.2），与 mode 无关（BR-37.5）。
func (s *Server) handleClip(w http.ResponseWriter, r *http.Request) {
	// M10：大请求体路由单独延长**读**期限（§8）；须在读 body 之前调用。
	extendReadDeadline(w)
	var req struct {
		URL   string `json:"url"`
		Title string `json:"title"`
		HTML  string `json:"html"`
		Mode  string `json:"mode"`
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
		assets               []clip.MediaAsset
		unlocalized          int
		purified             bool
	)
	if req.HTML != "" {
		result, err := clip.PurifyWithOptions(req.HTML, clip.Options{
			PageURL: req.URL,
			Mode:    req.Mode,
			Blobs:   s.blobs,
			Client:  s.mediaClient, // nil → clip 包的带闸门默认客户端（M10-T27）
		})
		if err != nil {
			writeInternalError(w, r, err)
			return
		}
		title = result.Title
		content = result.Content
		mode = result.Mode
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

	// 幂等判定（M4/BR-34.2/34.3）：非空 URL 命中 notes.source_url → 复用库内既有 id；
	// 否则以 ≥128 bit 摘要派生新 id。空 URL 回退为按正文内容摘要唯一化（BR-34.4）。
	noteID := ""
	if req.URL != "" {
		existing, err := s.store.GetNoteBySourceURL(req.URL)
		if err != nil {
			writeInternalError(w, r, err)
			return
		}
		if existing != "" {
			noteID = existing
		} else {
			noteID = "clip-" + hashURL(req.URL)
		}
	} else {
		noteID = "clip-" + store.HashBytes([]byte(fullContent))[:32]
	}

	// 组装附件映射（FR-38 / BR-38.2/38.3）：附件 id 由「笔记 id + 图片内容地址」派生，
	// 稳定可复现 → 重复剪藏同一 URL 时按 id upsert，不产生重复附件行。
	attachments := make([]sync.AttachmentItem, 0, len(assets))
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

	// 通过 sync 协议写入（先获取当前版本，再 push）
	current, err := s.store.GetNote(noteID)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	baseVer := 0
	if current != nil {
		baseVer = current.Version
	}

	resp, err := s.sync.Push(sync.PushItem{
		ID:           noteID,
		Title:        title,
		Content:      fullContent,
		BaseVersion:  baseVer,
		Version:      baseVer + 1,
		SourceDevice: "clip:web-extension",
		Attachments:  attachments,
	})
	if err != nil {
		writeInternalError(w, r, err)
		return
	}

	// 登记剪藏幂等键（普通笔记不写该列，M4/BR-34.3）
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

// hashURL 派生剪藏 id 摘要（≥128 bit，M4/BR-34.1）。
func hashURL(url string) string {
	return store.HashBytes([]byte(url))[:32]
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
