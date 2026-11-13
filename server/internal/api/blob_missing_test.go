package api

import (
	"bytes"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// FR-118 / BR-118.1\~118.3：`blobs` 行只记账，字节是否存在以磁盘文件为准。
//
// 现场：附件映射先到（`adjustBlobRef` 建行），字节上传尚未成功（无文件）。
// 旧实现 HEAD 200 / GET 500 / PUT 短路；新实现 HEAD/GET 404、PUT 自愈。
func TestBlobPhantomRowIs404AndPutRepairs(t *testing.T) {
	srv, st, dir := newM10Server(t)
	token := register(t, srv)

	payload := []byte("phantom-payload")
	hash := sha256Hex(payload)

	// 只建行，不写文件（等价于 sync.push 的附件映射先到）。
	if _, err := st.EnsureBlob(hash, len(payload)); err != nil {
		t.Fatalf("ensure blob row: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs", hash[:2], hash)); !os.IsNotExist(err) {
		t.Fatalf("前置条件失败：文件不应存在（err=%v）", err)
	}

	if rec := authReq(srv, token, http.MethodHead, "/api/v1/blobs/"+hash, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("HEAD 缺文件应 404，实际 %d", rec.Code)
	}
	if rec := authReq(srv, token, http.MethodGet, "/api/v1/blobs/"+hash, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("GET 缺文件应 404，实际 %d %s", rec.Code, rec.Body.String())
	} else if !strings.Contains(rec.Body.String(), "blob not found") {
		t.Fatalf("GET 404 文案应为 blob not found，实际 %s", rec.Body.String())
	}

	// PUT 应真正读体写盘，而不是「行已存在」短路。
	if rec := authReq(srv, token, http.MethodPut, "/api/v1/blobs/"+hash, payload); rec.Code != http.StatusOK {
		t.Fatalf("PUT 自愈应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs", hash[:2], hash)); err != nil {
		t.Fatalf("PUT 后文件应落盘：%v", err)
	}

	rec := authReq(srv, token, http.MethodGet, "/api/v1/blobs/"+hash, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET 应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	if !bytes.Equal(rec.Body.Bytes(), payload) {
		t.Fatalf("GET 字节不一致：%q", rec.Body.String())
	}
	if rec := authReq(srv, token, http.MethodHead, "/api/v1/blobs/"+hash, nil); rec.Code != http.StatusOK {
		t.Fatalf("HEAD 应 200，实际 %d", rec.Code)
	}

	// 引用计数仍只由附件映射维护，PUT 不应改动。
	if n, err := st.BlobRefCount(hash); err != nil || n != 0 {
		t.Fatalf("PUT 不应改引用计数（n=%d err=%v）", n, err)
	}
}

// FR-118 / AC-681：超限仍 413，且不落文件、不建行。
func TestBlobOverLimitStill413(t *testing.T) {
	srv, st, _ := newM10Server(t)
	token := register(t, srv)
	t.Setenv("SUI_MAX_BLOB_BYTES", "16")

	payload := []byte(strings.Repeat("x", 32))
	hash := sha256Hex(payload)
	rec := authReq(srv, token, http.MethodPut, "/api/v1/blobs/"+hash, payload)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("超限应 413，实际 %d %s", rec.Code, rec.Body.String())
	}
	exists, err := st.BlobExists(hash)
	if err != nil {
		t.Fatalf("blob exists: %v", err)
	}
	if exists {
		t.Fatalf("超限不应留下 blobs 行")
	}
}
