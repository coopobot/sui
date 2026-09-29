package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"sui/note-server/internal/sync"
)

// handleRegister 创建用户并返回 token（明文，供客户端 bootstrap 使用）。
func (s *Server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	if req.Username == "" || req.Password == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "username/password required"})
		return
	}
	// 简化：不存储密码哈希，仅演示 token 发放。生产应做哈希。
	token, err := s.store.CreateUser(req.Username, "plain:"+req.Password)
	if err != nil {
		writeJSON(w, http.StatusConflict, map[string]any{"ok": false, "error": "user exists"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "token": token, "username": req.Username})
}

// handleLogin 用户登录，返回新 token（简化：密码明文比对）。
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	if req.Username == "" || req.Password == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "username/password required"})
		return
	}
	// 简化实现：验证密码（明文前缀存储），成功则生成新 token
	// 生产环境应使用密码哈希 + 数据库查询
	token, err := s.store.LoginUser(req.Username, "plain:"+req.Password)
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "invalid credentials"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "token": token, "username": req.Username})
}

// handleLogout 吊销当前请求所用 Token 所属会话（不影响该用户其他会话）。
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "unauthorized"})
		return
	}
	if err := s.store.RevokeToken(token); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": "logout failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handlePush 处理客户端批量推送（逐条调用 sync.Push，汇总结果）。
func (s *Server) handlePush(w http.ResponseWriter, r *http.Request) {
	var req struct {
		ClientID  string              `json:"clientId"`
		Items     []sync.PushItem     `json:"items"`
		Notebooks []sync.NotebookItem `json:"notebooks"`
		Tags      []sync.TagItem      `json:"tags"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	type itemResult struct {
		ID             string `json:"id"`
		Accepted       bool   `json:"accepted"`
		ServerVersion  int    `json:"serverVersion,omitempty"`
		AppliedVersion int    `json:"appliedVersion,omitempty"`
	}
	results := make([]itemResult, 0, len(req.Items))
	for _, it := range req.Items {
		resp, err := s.sync.Push(it)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		results = append(results, itemResult{
			ID: it.ID, Accepted: resp.Accepted,
			ServerVersion: resp.ServerVersion, AppliedVersion: resp.AppliedVersion,
		})
	}
	notebookResults := make([]itemResult, 0, len(req.Notebooks))
	for _, it := range req.Notebooks {
		resp, err := s.sync.PushNotebook(it)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		notebookResults = append(notebookResults, itemResult{
			ID: it.ID, Accepted: resp.Accepted,
			ServerVersion: resp.ServerVersion, AppliedVersion: resp.AppliedVersion,
		})
	}
	tagResults := make([]itemResult, 0, len(req.Tags))
	for _, it := range req.Tags {
		resp, err := s.sync.PushTag(it)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		tagResults = append(tagResults, itemResult{
			ID: it.ID, Accepted: resp.Accepted,
			ServerVersion: resp.ServerVersion, AppliedVersion: resp.AppliedVersion,
		})
	}
	// 发送变更通知（WebSocket）
	s.hub.NotifyChange()

	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "results": results,
		"notebookResults": notebookResults, "tagResults": tagResults,
	})
}

// handlePull 返回自 since 之后的增量。
func (s *Server) handlePull(w http.ResponseWriter, r *http.Request) {
	sinceStr := r.URL.Query().Get("since")
	since := time.Time{}
	if sinceStr != "" {
		if t, err := time.Parse(time.RFC3339, sinceStr); err == nil {
			since = t
		}
	}
	rows, err := s.sync.Pull(since)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	type attOut struct {
		ID           string `json:"id"`
		Filename     string `json:"filename"`
		MimeKind     string `json:"mimeKind"`
		ByteSize     int    `json:"byteSize"`
		SHA256       string `json:"sha256"`
		StorageRef   string `json:"storageRef"`
		ThumbnailRef string `json:"thumbnailRef"`
		EmbeddedPos  int    `json:"embeddedPos"`
		IsDeleted    bool   `json:"isDeleted"`
		CreatedAt    string `json:"createdAt"`
	}
	type out struct {
		ID           string   `json:"id"`
		Title        string   `json:"title"`
		Content      string   `json:"content"`
		Version      int      `json:"version"`
		IsDeleted    bool     `json:"isDeleted"`
		Archived     bool     `json:"archived"`
		SourceDevice string   `json:"sourceDevice"`
		UpdatedAt    string   `json:"updatedAt"`
		Attachments  []attOut `json:"attachments,omitempty"`
		NotebookID   string   `json:"notebookId,omitempty"`
		TagIDs       []string `json:"tagIds,omitempty"`
	}
	list := make([]out, 0, len(rows))
	for _, pn := range rows {
		rw := pn.Note
		item := out{
			ID: rw.ID, Title: rw.Title, Content: rw.ContentMarkdown,
			Version: rw.Version, IsDeleted: rw.IsDeleted, Archived: rw.Archived,
			SourceDevice: rw.SourceDevice,
			NotebookID:   rw.NotebookID,
			UpdatedAt:    rw.UpdatedAt.UTC().Format(time.RFC3339),
			TagIDs:       pn.TagIDs,
		}
		for _, a := range pn.Attachments {
			item.Attachments = append(item.Attachments, attOut{
				ID: a.ID, Filename: a.Filename, MimeKind: a.MimeKind,
				ByteSize: a.ByteSize, SHA256: a.SHA256, StorageRef: a.StorageRef,
				ThumbnailRef: a.ThumbnailRef, EmbeddedPos: a.EmbeddedPos,
				IsDeleted: a.IsDeleted,
				CreatedAt: a.CreatedAt.UTC().Format(time.RFC3339),
			})
		}
		list = append(list, item)
	}
	// BUG5：根级笔记本 parentId 为空时省略字段，避免输出空串 ""，
	// 否则客户端会把它误判为非根节点（「创建后闪没」/「多端不同步」）。
	type nbOut struct {
		ID           string `json:"id"`
		ParentID     string `json:"parentId,omitempty"`
		Name         string `json:"name"`
		SortOrder    int    `json:"sortOrder"`
		Version      int    `json:"version"`
		IsDeleted    bool   `json:"isDeleted"`
		SourceDevice string `json:"sourceDevice"`
		UpdatedAt    string `json:"updatedAt"`
	}
	type tagOut struct {
		ID           string `json:"id"`
		Name         string `json:"name"`
		Version      int    `json:"version"`
		IsDeleted    bool   `json:"isDeleted"`
		SourceDevice string `json:"sourceDevice"`
		UpdatedAt    string `json:"updatedAt"`
	}
	nbRows, err := s.sync.PullNotebooks(since)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	notebooks := make([]nbOut, 0, len(nbRows))
	for _, nb := range nbRows {
		notebooks = append(notebooks, nbOut{
			ID: nb.ID, ParentID: nb.ParentID, Name: nb.Name, SortOrder: nb.SortOrder,
			Version: nb.Version, IsDeleted: nb.IsDeleted, SourceDevice: nb.SourceDevice,
			UpdatedAt: nb.UpdatedAt.UTC().Format(time.RFC3339),
		})
	}
	tagRows, err := s.sync.PullTags(since)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	tags := make([]tagOut, 0, len(tagRows))
	for _, tg := range tagRows {
		tags = append(tags, tagOut{
			ID: tg.ID, Name: tg.Name, Version: tg.Version,
			IsDeleted: tg.IsDeleted, SourceDevice: tg.SourceDevice,
			UpdatedAt: tg.UpdatedAt.UTC().Format(time.RFC3339),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "notes": list,
		"notebooks": notebooks, "tags": tags,
	})
}

// handleBlobHead 检查 hash 是否存在（内容寻址去重）。
func (s *Server) handleBlobHead(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	exists, err := s.store.BlobExists(hash)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if exists {
		w.WriteHeader(http.StatusOK)
		return
	}
	w.WriteHeader(http.StatusNotFound)
}

// handleBlobPut 上传 hash 对应的字节；已存在则幂等返回。
//
// 只负责字节与登记，不调整引用计数——refcount 由附件映射（sync/push 携带的
// attachments）驱动，见 store.SyncAttachments。
func (s *Server) handleBlobPut(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	exists, err := s.store.BlobExists(hash)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if !exists {
		if _, err := s.blobs.Put(hash, r.Body); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
	}
	if _, err := s.store.EnsureBlob(hash, int(r.ContentLength)); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleBlobGet 下载 hash 对应的 blob 字节。
func (s *Server) handleBlobGet(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	exists, err := s.store.BlobExists(hash)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if !exists {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "blob not found"})
		return
	}
	reader, err := s.blobs.Open(hash)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	defer reader.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", "attachment; filename="+hash)
	http.ServeContent(w, r, hash, time.Time{}, reader)
}

// ---- 修订历史 ----

// handleListRevisions 返回指定笔记的修订列表。
func (s *Server) handleListRevisions(w http.ResponseWriter, r *http.Request) {
	noteID := r.PathValue("id")
	revs, err := s.store.ListRevisions(noteID, 50)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	type revOut struct {
		Version      int    `json:"version"`
		Title        string `json:"title"`
		Content      string `json:"content"`
		SourceDevice string `json:"sourceDevice"`
		IsConflict   bool   `json:"isConflict"`
		CreatedAt    string `json:"createdAt"`
	}
	list := make([]revOut, 0, len(revs))
	for _, r := range revs {
		list = append(list, revOut{
			Version:      r.Version,
			Title:        r.Title,
			Content:      r.ContentMarkdown,
			SourceDevice: r.SourceDevice,
			IsConflict:   r.IsConflict,
			CreatedAt:    r.CreatedAt.UTC().Format(time.RFC3339),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "revisions": list})
}

// handleGetRevision 返回指定版本的修订详情。
func (s *Server) handleGetRevision(w http.ResponseWriter, r *http.Request) {
	noteID := r.PathValue("id")
	verStr := r.PathValue("version")
	version, err := strconv.Atoi(verStr)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid version"})
		return
	}
	rev, err := s.store.GetRevision(noteID, version)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	if rev == nil {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "revision not found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true,
		"revision": map[string]any{
			"version":      rev.Version,
			"title":        rev.Title,
			"content":      rev.ContentMarkdown,
			"sourceDevice": rev.SourceDevice,
			"isConflict":   rev.IsConflict,
			"createdAt":    rev.CreatedAt.UTC().Format(time.RFC3339),
		},
	})
}
