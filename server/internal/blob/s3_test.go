package blob

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeS3 是只实现 Put/Get/Head/Delete 的最小 S3 兼容端（path-style）。
type fakeS3 struct {
	mu      sync.Mutex
	objects map[string][]byte
}

func (f *fakeS3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	key := strings.TrimPrefix(r.URL.Path, "/bucket/")
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.objects == nil {
		f.objects = map[string][]byte{}
	}
	switch r.Method {
	case http.MethodPut:
		body, _ := io.ReadAll(r.Body)
		f.objects[key] = body
		w.Header().Set("ETag", `"x"`)
		w.WriteHeader(http.StatusOK)
	case http.MethodGet:
		body, ok := f.objects[key]
		if !ok {
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`<?xml version="1.0"?><Error><Code>NoSuchKey</Code><Message>missing</Message></Error>`))
			return
		}
		w.Header().Set("Content-Length", itoa(len(body)))
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
	case http.MethodHead:
		body, ok := f.objects[key]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Length", itoa(len(body)))
		w.WriteHeader(http.StatusOK)
	case http.MethodDelete:
		delete(f.objects, key)
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [16]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

func newFakeS3(t *testing.T) (*S3, *fakeS3) {
	t.Helper()
	fake := &fakeS3{}
	srv := httptest.NewServer(fake)
	t.Cleanup(srv.Close)
	store, err := NewS3(context.Background(), S3Config{
		Endpoint:  srv.URL,
		Region:    "us-east-1",
		Bucket:    "bucket",
		Prefix:    "sui/",
		AccessKey: "test",
		SecretKey: "test",
		PathStyle: true,
		TempDir:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("new s3: %v", err)
	}
	return store, fake
}

func hashOf(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func TestS3PutGetStatDelete(t *testing.T) {
	store, _ := newFakeS3(t)
	payload := []byte("hello-s3")
	hash := hashOf(payload)

	if n, err := store.Put(hash, bytes.NewReader(payload)); err != nil || n != int64(len(payload)) {
		t.Fatalf("Put: n=%d err=%v", n, err)
	}
	size, ok, err := store.Stat(hash)
	if err != nil || !ok || size != int64(len(payload)) {
		t.Fatalf("Stat: size=%d ok=%v err=%v", size, ok, err)
	}
	rc, err := store.Open(hash)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	got, _ := io.ReadAll(rc)
	rc.Close()
	if !bytes.Equal(got, payload) {
		t.Fatalf("Open bytes mismatch: %q", got)
	}
	if err := store.Delete(hash); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, ok, _ := store.Stat(hash); ok {
		t.Fatalf("Delete 后仍存在")
	}
}

func TestS3DigestMismatch(t *testing.T) {
	store, _ := newFakeS3(t)
	hash := hashOf([]byte("expected"))
	if _, err := store.Put(hash, bytes.NewReader([]byte("tampered"))); err != ErrDigestMismatch {
		t.Fatalf("应 ErrDigestMismatch，实际 %v", err)
	}
	if _, ok, _ := store.Stat(hash); ok {
		t.Fatalf("摘要不一致不应留下对象")
	}
}

func TestS3ChunkedComplete(t *testing.T) {
	store, _ := newFakeS3(t)
	const chunk = 1 << 20
	payload := bytes.Repeat([]byte("ab"), chunk) // 2 MiB
	hash := hashOf(payload)

	status, err := store.InitUpload(hash, int64(len(payload)), chunk)
	if err != nil || status.Complete {
		t.Fatalf("init: %+v err=%v", status, err)
	}
	if _, err := store.PutChunk(hash, 0, bytes.NewReader(payload[:chunk])); err != nil {
		t.Fatalf("part 0: %v", err)
	}
	if _, err := store.PutChunk(hash, 1, bytes.NewReader(payload[chunk:])); err != nil {
		t.Fatalf("part 1: %v", err)
	}
	n, err := store.CompleteUpload(hash)
	if err != nil || n != int64(len(payload)) {
		t.Fatalf("complete: n=%d err=%v", n, err)
	}
	size, ok, err := store.Stat(hash)
	if err != nil || !ok || size != int64(len(payload)) {
		t.Fatalf("stat after complete: %d %v %v", size, ok, err)
	}
}

func TestS3RequiresBucket(t *testing.T) {
	if _, err := NewS3(context.Background(), S3Config{}); err == nil {
		t.Fatal("缺少 bucket 应返回错误")
	}
}
