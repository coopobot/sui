package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"sui/note-server/internal/blob"
)

func initUpload(t *testing.T, srv *Server, token, hash string, size, chunkSize int64) *httptest.ResponseRecorder {
	t.Helper()
	body, _ := json.Marshal(map[string]int64{"size": size, "chunkSize": chunkSize})
	return authReq(srv, token, http.MethodPost, "/api/v1/blobs/"+hash+"/upload", body)
}

func putChunk(t *testing.T, srv *Server, token, hash string, index int, data []byte) *httptest.ResponseRecorder {
	t.Helper()
	return authReq(srv, token, http.MethodPut,
		"/api/v1/blobs/"+hash+"/upload/"+chunkIndex(index), data)
}

func chunkIndex(i int) string { return strconv.Itoa(i) }

type uploadStatus struct {
	Size      int64 `json:"size"`
	ChunkSize int64 `json:"chunkSize"`
	Uploaded  []int `json:"uploaded"`
	Complete  bool  `json:"complete"`
}

// FR-119 / AC-683\~685：init 幂等、乱序 / 重复分片、续传、complete 与 GET。
func TestChunkUploadResumeAndComplete(t *testing.T) {
	srv, _, dir := newM10Server(t)
	token := register(t, srv)

	const chunkSize = 1 << 20
	payload := bytes.Repeat([]byte("0123456789abcdef"), (3*chunkSize+123)/16+1)
	payload = payload[:3*chunkSize]
	hash := sha256Hex(payload)

	rec := initUpload(t, srv, token, hash, int64(len(payload)), chunkSize)
	if rec.Code != http.StatusOK {
		t.Fatalf("init: %d %s", rec.Code, rec.Body.String())
	}
	var st uploadStatus
	json.Unmarshal(rec.Body.Bytes(), &st)
	if st.Complete || len(st.Uploaded) != 0 || st.ChunkSize != chunkSize {
		t.Fatalf("init status 异常：%+v", st)
	}

	parts := [][]byte{
		payload[:chunkSize],
		payload[chunkSize : 2*chunkSize],
		payload[2*chunkSize:],
	}
	for _, idx := range []int{2, 0, 2} {
		if r := putChunk(t, srv, token, hash, idx, parts[idx]); r.Code != http.StatusOK {
			t.Fatalf("put %d: %d %s", idx, r.Code, r.Body.String())
		}
	}

	// 重新 init 应只报 [0,2]，补 1 后再报全量。
	rec = initUpload(t, srv, token, hash, int64(len(payload)), chunkSize)
	json.Unmarshal(rec.Body.Bytes(), &st)
	if len(st.Uploaded) != 2 || st.Uploaded[0] != 0 || st.Uploaded[1] != 2 {
		t.Fatalf("续传状态应为 [0,2]，实际 %+v", st)
	}
	if r := putChunk(t, srv, token, hash, 1, parts[1]); r.Code != http.StatusOK {
		t.Fatalf("put 1: %d %s", r.Code, r.Body.String())
	}
	rec = initUpload(t, srv, token, hash, int64(len(payload)), chunkSize)
	json.Unmarshal(rec.Body.Bytes(), &st)
	if len(st.Uploaded) != 3 {
		t.Fatalf("补片后应为 [0,1,2]，实际 %+v", st)
	}

	rec = authReq(srv, token, http.MethodPost, "/api/v1/blobs/"+hash+"/upload/complete", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("complete: %d %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs", hash[:2], hash)); err != nil {
		t.Fatalf("最终文件应存在：%v", err)
	}
	rec = authReq(srv, token, http.MethodGet, "/api/v1/blobs/"+hash, nil)
	if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), payload) {
		t.Fatalf("GET 不一致：%d len=%d", rec.Code, rec.Body.Len())
	}
	// 重复 complete 幂等。
	if r := authReq(srv, token, http.MethodPost, "/api/v1/blobs/"+hash+"/upload/complete", nil); r.Code != http.StatusOK {
		t.Fatalf("重复 complete 应 200，实际 %d", r.Code)
	}
}

// FR-119 / AC-686：缺片 → 409 + missing[]，不产生最终文件。
func TestChunkUploadMissingParts(t *testing.T) {
	srv, _, dir := newM10Server(t)
	token := register(t, srv)
	const chunkSize = 1 << 20
	payload := bytes.Repeat([]byte("x"), 2*chunkSize)
	hash := sha256Hex(payload)

	initUpload(t, srv, token, hash, int64(len(payload)), chunkSize)
	putChunk(t, srv, token, hash, 0, payload[:chunkSize])

	rec := authReq(srv, token, http.MethodPost, "/api/v1/blobs/"+hash+"/upload/complete", nil)
	if rec.Code != http.StatusConflict {
		t.Fatalf("缺片应 409，实际 %d %s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("missing")) {
		t.Fatalf("应返回 missing[]：%s", rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs", hash[:2], hash)); !os.IsNotExist(err) {
		t.Fatalf("缺片不应产生最终文件")
	}
}

// FR-119 / AC-687：拼接摘要与 hash 不一致 → 400，不留最终文件。
func TestChunkUploadDigestMismatch(t *testing.T) {
	srv, _, dir := newM10Server(t)
	token := register(t, srv)
	const chunkSize = 1 << 20
	expected := bytes.Repeat([]byte("good"), chunkSize/4)
	hash := sha256Hex(expected)
	tampered := bytes.Repeat([]byte("evil"), chunkSize/4)

	initUpload(t, srv, token, hash, int64(len(tampered)), chunkSize)
	putChunk(t, srv, token, hash, 0, tampered)
	rec := authReq(srv, token, http.MethodPost, "/api/v1/blobs/"+hash+"/upload/complete", nil)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("摘要不一致应 400，实际 %d %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs", hash[:2], hash)); !os.IsNotExist(err) {
		t.Fatalf("摘要不一致不应留下最终文件")
	}
}

// FR-119 / AC-688：边界参数一律 400。
func TestChunkUploadBounds(t *testing.T) {
	srv, _, _ := newM10Server(t)
	token := register(t, srv)
	hash := sha256Hex([]byte("payload"))

	if rec := initUpload(t, srv, token, hash, 0, 1<<20); rec.Code != http.StatusBadRequest {
		t.Fatalf("size=0 应 400，实际 %d", rec.Code)
	}
	if rec := initUpload(t, srv, token, hash, 2<<20, 512<<10); rec.Code != http.StatusBadRequest {
		t.Fatalf("chunkSize<1MiB 应 400，实际 %d", rec.Code)
	}
	initUpload(t, srv, token, hash, 2<<20, 1<<20)
	if rec := putChunk(t, srv, token, hash, 9, []byte("x")); rec.Code != http.StatusBadRequest {
		t.Fatalf("index 越界应 400，实际 %d", rec.Code)
	}
	if rec := putChunk(t, srv, token, hash, 0, []byte("short")); rec.Code != http.StatusBadRequest {
		t.Fatalf("分片长度不符应 400，实际 %d", rec.Code)
	}
}

// FR-119 / AC-691：超过 TTL 的未完成会话被清理。
func TestChunkUploadCleanup(t *testing.T) {
	srv, _, dir := newM10Server(t)
	token := register(t, srv)
	const chunkSize = 1 << 20
	payload := bytes.Repeat([]byte("z"), chunkSize)
	hash := sha256Hex(payload)
	initUpload(t, srv, token, hash, int64(len(payload)), chunkSize)

	upDir := filepath.Join(dir, "blobs", hash[:2], hash+".upload")
	meta := filepath.Join(upDir, "meta.json")
	old := time.Now().Add(-25 * time.Hour)
	if err := os.Chtimes(meta, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}
	cs, ok := srv.blobs.(blob.ChunkedStore)
	if !ok {
		t.Fatal("Local 应实现 ChunkedStore")
	}
	if err := cs.CleanupUploads(time.Now()); err != nil {
		t.Fatalf("cleanup: %v", err)
	}
	if _, err := os.Stat(upDir); !os.IsNotExist(err) {
		t.Fatalf("超时会话目录应被清理")
	}
}
