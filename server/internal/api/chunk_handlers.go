package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"sui/note-server/internal/blob"
)

// 分片断点续传端点（M20 / FR-119 / ADR-044）。
//
// 与整包 PUT 共用同一内容寻址路径与摘要校验；这里只负责 HTTP 语义与错误码。

func (s *Server) chunkStore(w http.ResponseWriter, r *http.Request) (blob.ChunkedStore, bool) {
	cs, ok := s.blobs.(blob.ChunkedStore)
	if !ok {
		writeJSON(w, http.StatusNotImplemented, map[string]any{"ok": false, "error": "chunked upload unsupported"})
		return nil, false
	}
	return cs, true
}

// handleUploadInit：创建 / 复用分片会话，返回已上传分片供续传。
func (s *Server) handleUploadInit(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	if !validSHA256(hash) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	var req struct {
		Size      int64 `json:"size"`
		ChunkSize int64 `json:"chunkSize"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}
	if req.Size <= 0 || req.Size > maxBlobBytes() ||
		req.ChunkSize < blob.ChunkMinSize || req.ChunkSize > blob.ChunkMaxSize {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	cs, ok := s.chunkStore(w, r)
	if !ok {
		return
	}
	// 单用户自托管：新建会话时顺带清一次超时会话（BR-119.9）。
	_ = cs.CleanupUploads(time.Now())
	status, err := cs.InitUpload(hash, req.Size, req.ChunkSize)
	switch {
	case errors.Is(err, blob.ErrUploadMismatch):
		writeJSON(w, http.StatusConflict, map[string]any{"ok": false, "error": "upload session mismatch"})
		return
	case errors.Is(err, blob.ErrChunkSizeMismatch):
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	case err != nil:
		writeInternalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "size": status.Size, "chunkSize": status.ChunkSize,
		"uploaded": status.Uploaded, "complete": status.Complete,
	})
}

// handleUploadPart：写入一个分片（乱序 / 重复幂等）。
func (s *Server) handleUploadPart(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	if !validSHA256(hash) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	index, err := strconv.ParseInt(r.PathValue("index"), 10, 64)
	if err != nil || index < 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	cs, ok := s.chunkStore(w, r)
	if !ok {
		return
	}
	body := http.MaxBytesReader(w, r.Body, blob.ChunkMaxSize+1)
	n, err := cs.PutChunk(hash, index, body)
	switch {
	case errors.Is(err, blob.ErrChunkOutOfRange), errors.Is(err, blob.ErrChunkSizeMismatch):
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	case errors.Is(err, blob.ErrUploadNotFound):
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "upload session not found"})
		return
	case err != nil:
		writeInternalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "index": index, "received": n})
}

// handleUploadComplete：全片齐全后流式拼接、校验并转正。
func (s *Server) handleUploadComplete(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	if !validSHA256(hash) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	cs, ok := s.chunkStore(w, r)
	if !ok {
		return
	}
	size, err := cs.CompleteUpload(hash)
	var missing *blob.MissingChunksError
	switch {
	case errors.As(err, &missing):
		writeJSON(w, http.StatusConflict, map[string]any{
			"ok": false, "error": "missing chunks", "missing": missing.Missing,
		})
		return
	case errors.Is(err, blob.ErrDigestMismatch):
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid payload"})
		return
	case errors.Is(err, blob.ErrUploadNotFound):
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "upload session not found"})
		return
	case err != nil:
		writeInternalError(w, r, err)
		return
	}
	// 引用计数仍由附件映射维护；这里只做 blob 行登记（与整包 PUT 同口径）。
	if _, err := s.store.EnsureBlob(hash, int(size)); err != nil {
		writeInternalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "size": size})
}

// handleUploadAbort：放弃会话并清理临时目录。
func (s *Server) handleUploadAbort(w http.ResponseWriter, r *http.Request) {
	hash := r.PathValue("hash")
	if !validSHA256(hash) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid parameter"})
		return
	}
	cs, ok := s.chunkStore(w, r)
	if !ok {
		return
	}
	if err := cs.AbortUpload(hash); err != nil {
		writeInternalError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
