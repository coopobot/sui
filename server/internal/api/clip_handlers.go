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

	// 生成 note id（基于 URL 做幂等：同一 URL 多次剪藏 → 更新同一笔记）
	noteID := "clip-" + hashURL(req.URL)
	if req.URL == "" {
		noteID = "clip-" + store.HashBytes([]byte(fullContent[:min(len(fullContent), 200)]))[:16]
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

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"noteId":  noteID,
		"title":   title,
		"version": resp.AppliedVersion,
		"url":     req.URL,
	})
}

func hashURL(url string) string {
	return store.HashBytes([]byte(url))[:16]
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
