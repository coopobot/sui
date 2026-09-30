package api

import (
	"encoding/json"
	"net/http"

	"sui/note-server/internal/clip"
	"sui/note-server/internal/store"
	"sui/note-server/internal/sync"
)

// handleClip 处理网页剪藏：接收 URL + HTML，净化为 Markdown，创建新笔记。
func (s *Server) handleClip(w http.ResponseWriter, r *http.Request) {
	var req struct {
		URL   string `json:"url"`
		Title string `json:"title"`
		HTML  string `json:"html"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	if req.URL == "" && req.HTML == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "url or html required"})
		return
	}

	// 净化 HTML → Markdown
	var title, content string
	if req.HTML != "" {
		result, err := clip.Purify(req.HTML, req.URL)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": "purify failed: " + err.Error()})
			return
		}
		title = result.Title
		content = result.Content
	}
	// 客户端传的标题优先
	if req.Title != "" {
		title = req.Title
	}
	if title == "" {
		title = "未命名剪藏"
	}

	// 正文开头附上来源链接
	sourceLine := "> 来源：[" + req.URL + "](" + req.URL + ")\n\n"
	fullContent := sourceLine + content

	// 幂等判定（M4/BR-34.2/34.3）：非空 URL 命中 notes.source_url → 复用库内既有 id；
	// 否则以 ≥128 bit 摘要派生新 id。空 URL 回退为按正文内容摘要唯一化（BR-34.4）。
	noteID := ""
	if req.URL != "" {
		existing, err := s.store.GetNoteBySourceURL(req.URL)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
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

	// 通过 sync 协议写入（先获取当前版本，再 push）
	current, err := s.store.GetNote(noteID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
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
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}

	// 登记剪藏幂等键（普通笔记不写该列，M4/BR-34.3）
	if req.URL != "" {
		if err := s.store.SetNoteSourceURL(noteID, req.URL); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
	}

	// 发送变更通知（WebSocket）
	s.hub.NotifyChange()

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"noteId":  noteID,
		"title":   title,
		"version": resp.AppliedVersion,
		"url":     req.URL,
	})
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
