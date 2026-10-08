package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"sui/note-server/internal/blob"
	"sui/note-server/internal/store"
)

// M10 安全加固的门禁测试（AC-168~AC-171 与 BR-52.5）。
//
// 与既有测试的差别：这里需要断言「**是否落盘**」，因此要拿到**已知的数据目录**，
// 故自带一个 newM10Server（newTestServer 把目录藏在 t.TempDir 里无法检查）。

func newM10Server(t *testing.T) (*Server, *store.Store, string) {
	t.Helper()
	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "sui.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	blobs, err := blob.NewLocal(dir)
	if err != nil {
		t.Fatalf("init blob: %v", err)
	}
	return New(st, blobs), st, dir
}

// assertNoStrayFiles 断言数据目录内没有越界文件与临时文件残留。
func assertNoStrayFiles(t *testing.T, dir string) {
	t.Helper()
	err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		if strings.Contains(info.Name(), "pwned") {
			t.Errorf("越界文件被创建：%s", p)
		}
		if strings.HasSuffix(info.Name(), ".tmp") {
			t.Errorf("临时文件残留：%s", p)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk: %v", err)
	}
}

// assertBlobsEmpty 断言内容寻址存储子树为空（一次都不该触盘）。
func assertBlobsEmpty(t *testing.T, dir string) {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(dir, "blobs"))
	if err != nil {
		if os.IsNotExist(err) {
			return
		}
		t.Fatalf("read blobs dir: %v", err)
	}
	if len(entries) != 0 {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("blobs 目录不应有任何内容，实际 %v", names)
	}
}

// ---- AC-168：非法标识符被拒且不落盘 ----

func TestM10InvalidBlobHashRejected(t *testing.T) {
	srv, _, dir := newM10Server(t)
	token := register(t, srv)

	// 用**真实 TCP + ServeMux** 复现 §2.3 的实测条件（转义路径命中 + 解码取值）。
	ts := httptest.NewServer(srv.Router())
	defer ts.Close()
	client := &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}

	cases := []struct {
		name string
		hash string
	}{
		{"转义路径穿越", "%2e%2e%2f%2e%2e%2fpwned.txt"},
		{"点斜杠穿越", "..%2f..%2fpwned.txt"},
		{"四点点斜杠", "....%2f%2fpwned.txt"},
		{"大写 hex", strings.Repeat("A", 64)},
		{"超短 63", strings.Repeat("a", 63)},
		{"超长 65", strings.Repeat("a", 65)},
		{"非 hex", strings.Repeat("z", 64)},
		{"含斜杠前缀", "%2fetc%2fpasswd"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, err := http.NewRequest(http.MethodPut, ts.URL+"/api/v1/blobs/"+tc.hash, strings.NewReader("x"))
			if err != nil {
				t.Fatalf("new request: %v", err)
			}
			req.Header.Set("Authorization", "Bearer "+token)
			resp, err := client.Do(req)
			if err != nil {
				t.Fatalf("do: %v", err)
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusBadRequest {
				t.Fatalf("期望 400（拒绝非法 hash），实际 %d", resp.StatusCode)
			}
		})
	}

	// 非法取值必须在进入存储层**之前**被拒：一次都不该创建分片目录 / 临时文件。
	assertNoStrayFiles(t, dir)
	assertBlobsEmpty(t, dir)
}

// ---- AC-169：路径不越界（存储层断言兜底）----

func TestM10LocalStoreRejectsEscape(t *testing.T) {
	dir := t.TempDir()
	l, err := blob.NewLocal(dir)
	if err != nil {
		t.Fatalf("new local: %v", err)
	}
	// 注意：`a/../../pwned` 这类取值经 filepath.Join 的 Clean 会**落回根内**
	// （dir/pwned），既不越界也无副作用，故不作为负例；此处只用真正越界的取值。
	for _, hash := range []string{"../pwned", "../../pwned", "aa/../../../../pwned"} {
		if _, err := l.Put(hash, strings.NewReader("x")); err == nil {
			t.Errorf("Put(%q) 应当失败（越出存储根）", hash)
		}
		if _, err := l.Open(hash); err == nil {
			t.Errorf("Open(%q) 应当失败（越出存储根）", hash)
		}
		if _, err := l.Path(hash); err == nil {
			t.Errorf("Path(%q) 应当失败（越出存储根）", hash)
		}
		if err := l.Delete(hash); err == nil {
			t.Errorf("Delete(%q) 应当失败（越出存储根）", hash)
		}
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dir), "pwned")); !os.IsNotExist(err) {
		t.Errorf("越界路径竟被创建")
	}
}

// ---- AC-170 / BR-52.3：上传字节与声明摘要不一致 ----

func TestM10DigestMismatchRejected(t *testing.T) {
	srv, st, dir := newM10Server(t)
	token := register(t, srv)

	declared := sha256Hex([]byte("the-real-payload"))
	rec := authReq(srv, token, http.MethodPut, "/api/v1/blobs/"+declared, []byte("tampered-payload"))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("期望 400（摘要不一致），实际 %d %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "invalid payload") {
		t.Errorf("错误体应为 invalid payload，实际 %s", rec.Body.String())
	}

	exists, err := st.BlobExists(declared)
	if err != nil {
		t.Fatalf("blob exists: %v", err)
	}
	if exists {
		t.Errorf("摘要不一致时不应写入 blobs 行")
	}
	if _, err := os.Stat(filepath.Join(dir, "blobs", declared[:2], declared)); !os.IsNotExist(err) {
		t.Errorf("摘要不一致时最终路径不应存在文件")
	}
	assertNoStrayFiles(t, dir)
}

// ---- 正例：合法上传 / 下载 / HEAD 不回归，且记账用实际字节 ----

func TestM10BlobRoundTripAndAccounting(t *testing.T) {
	srv, st, dir := newM10Server(t)
	token := register(t, srv)

	payload := []byte("hello-m10-blob")
	hash := sha256Hex(payload)

	rec := authReq(srv, token, http.MethodPut, "/api/v1/blobs/"+hash, payload)
	if rec.Code != http.StatusOK {
		t.Fatalf("上传失败：%d %s", rec.Code, rec.Body.String())
	}

	// 记账用**实际读入字节**（不再采信 Content-Length）。
	exists, err := st.BlobExists(hash)
	if err != nil || !exists {
		t.Fatalf("blobs 行应存在（err=%v exists=%v）", err, exists)
	}

	// 落盘权限：文件 0600、分片目录 0700（§4.2）。
	fpath := filepath.Join(dir, "blobs", hash[:2], hash)
	fi, err := os.Stat(fpath)
	if err != nil {
		t.Fatalf("内容文件应存在：%v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Errorf("内容文件权限应为 0600，实际 %o", perm)
	}
	di, err := os.Stat(filepath.Join(dir, "blobs", hash[:2]))
	if err != nil {
		t.Fatalf("分片目录应存在：%v", err)
	}
	if perm := di.Mode().Perm(); perm != 0o700 {
		t.Errorf("分片目录权限应为 0700，实际 %o", perm)
	}

	// HEAD
	if rec := authReq(srv, token, http.MethodHead, "/api/v1/blobs/"+hash, nil); rec.Code != http.StatusOK {
		t.Errorf("HEAD 应 200，实际 %d", rec.Code)
	}
	// GET
	rec = authReq(srv, token, http.MethodGet, "/api/v1/blobs/"+hash, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET 应 200，实际 %d", rec.Code)
	}
	if !bytes.Equal(rec.Body.Bytes(), payload) {
		t.Errorf("GET 内容不一致：%q", rec.Body.String())
	}
	if got := rec.Header().Get("X-Content-Type-Options"); got != "nosniff" {
		t.Errorf("应补 nosniff 响应头，实际 %q", got)
	}
	// 幂等重传
	if rec := authReq(srv, token, http.MethodPut, "/api/v1/blobs/"+hash, payload); rec.Code != http.StatusOK {
		t.Errorf("幂等重传应 200，实际 %d", rec.Code)
	}
	// 未登记的合法 hash → 404
	missing := sha256Hex([]byte("not-uploaded"))
	if rec := authReq(srv, token, http.MethodHead, "/api/v1/blobs/"+missing, nil); rec.Code != http.StatusNotFound {
		t.Errorf("未登记 hash 的 HEAD 应 404，实际 %d", rec.Code)
	}
}

// ---- AC-171 / BR-52.4：失败响应不泄露内部信息 ----

func TestM10InternalErrorSanitized(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/blobs/x", nil)
	writeInternalError(rec, req, fmt.Errorf("open /var/lib/sui/blobs/ab/cd: no such file or directory"))

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("期望 500，实际 %d", rec.Code)
	}
	body := rec.Body.String()
	for _, leak := range []string{"/", "\\", "sql", "SELECT", ".db", "no such file"} {
		if strings.Contains(body, leak) {
			t.Errorf("响应体泄露内部信息 %q：%s", leak, body)
		}
	}
	if !strings.Contains(body, "internal error") {
		t.Errorf("应为通用错误体，实际 %s", body)
	}
}

// TestM10PingInternalErrorSanitized 端到端：内部失败也只回通用错误体。
func TestM10PingInternalErrorSanitized(t *testing.T) {
	srv, st, _ := newM10Server(t)
	st.Close() // 制造内部错误

	req := httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil)
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("期望 500，实际 %d", rec.Code)
	}
	var payload map[string]any
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if payload["error"] != "internal error" {
		t.Errorf("应为通用错误体，实际 %v", payload["error"])
	}
}

// ---- BR-52.5：CORS 默认拒绝 ----

func TestM10CORSDefaultDeny(t *testing.T) {
	srv := newTestServer(t)
	t.Setenv("SUI_ALLOWED_ORIGINS", "")

	// 预检：无白名单 → 不回任何 Allow-* 头（浏览器据此拒绝跨域）。
	req := httptest.NewRequest(http.MethodOptions, "/api/v1/ping", nil)
	req.Header.Set("Origin", "http://evil.example")
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("预检应 204，实际 %d", rec.Code)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("未配置白名单不应回 Allow-Origin，实际 %q", got)
	}
	if got := rec.Header().Get("Access-Control-Allow-Headers"); got != "" {
		t.Errorf("未配置白名单不应回 Allow-Headers，实际 %q", got)
	}

	// 普通请求同样不回。
	req = httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil)
	req.Header.Set("Origin", "http://evil.example")
	rec = httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("未配置白名单不应回 Allow-Origin，实际 %q", got)
	}
}

func TestM10CORSAllowlistExactMatch(t *testing.T) {
	srv := newTestServer(t)
	t.Setenv("SUI_ALLOWED_ORIGINS", "http://ok.example")

	req := httptest.NewRequest(http.MethodOptions, "/api/v1/ping", nil)
	req.Header.Set("Origin", "http://ok.example")
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "http://ok.example" {
		t.Errorf("白名单命中应回显该来源，实际 %q", got)
	}

	req = httptest.NewRequest(http.MethodOptions, "/api/v1/ping", nil)
	req.Header.Set("Origin", "http://evil.example")
	rec = httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("未命中白名单不应回 Allow-Origin，实际 %q", got)
	}

	// 只做精确匹配：前缀相同的来源不放行。
	req = httptest.NewRequest(http.MethodOptions, "/api/v1/ping", nil)
	req.Header.Set("Origin", "http://ok.example.evil.com")
	rec = httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("前缀相似不应放行，实际 %q", got)
	}
}

func TestM10WSOriginPatterns(t *testing.T) {
	if got := wsOriginPatterns(nil); len(got) != 0 {
		t.Errorf("未配置应为空（=仅同源），实际 %v", got)
	}
	if got := wsOriginPatterns([]string{"*"}); len(got) != 1 || got[0] != "*" {
		t.Errorf("显式 * 应透传，实际 %v", got)
	}
	got := wsOriginPatterns([]string{"https://a.example:5173", "http://b.example"})
	want := []string{"a.example:5173", "b.example"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("应转换为 host 模式 %v，实际 %v", want, got)
	}
}

// ---- M10-T25：请求体 / 条目上限 ----

func TestM10BodyLimits(t *testing.T) {
	t.Run("clips 超限 413", func(t *testing.T) {
		srv, _, _ := newM10Server(t)
		token := register(t, srv) // 先注册（此时上限还是默认值）
		t.Setenv("SUI_MAX_BODY_BYTES", "16")

		body, _ := json.Marshal(map[string]any{
			"url": "http://a.example", "html": strings.Repeat("x", 64),
		})
		rec := authReq(srv, token, http.MethodPost, "/api/v1/clips", body)
		if rec.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("期望 413，实际 %d %s", rec.Code, rec.Body.String())
		}
	})

	t.Run("push 超限 413", func(t *testing.T) {
		srv, _, _ := newM10Server(t)
		token := register(t, srv)
		t.Setenv("SUI_MAX_BODY_BYTES", "16")

		body := []byte(`{"clientId":"dev-a","items":[]}` + strings.Repeat(" ", 64))
		rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", body)
		if rec.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("期望 413，实际 %d %s", rec.Code, rec.Body.String())
		}
	})

	t.Run("push 条目数上限", func(t *testing.T) {
		srv, _, _ := newM10Server(t)
		token := register(t, srv)
		t.Setenv("SUI_MAX_PUSH_ITEMS", "1")

		body, _ := json.Marshal(map[string]any{
			"clientId": "dev-a",
			"items": []map[string]any{
				{"id": "n1", "title": "a", "content": "x", "baseVersion": 0, "version": 1},
				{"id": "n2", "title": "b", "content": "y", "baseVersion": 0, "version": 1},
			},
		})
		rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("期望 400，实际 %d %s", rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), "too many items") {
			t.Errorf("错误体应为 too many items，实际 %s", rec.Body.String())
		}
	})

	t.Run("blob 超限 413", func(t *testing.T) {
		srv, _, _ := newM10Server(t)
		token := register(t, srv)
		t.Setenv("SUI_MAX_BLOB_BYTES", "4")

		payload := []byte("0123456789")
		rec := authReq(srv, token, http.MethodPut, "/api/v1/blobs/"+sha256Hex(payload), payload)
		if rec.Code != http.StatusRequestEntityTooLarge {
			t.Fatalf("期望 413，实际 %d %s", rec.Code, rec.Body.String())
		}
	})
}

// ---- AC-168：路径参数标识符 / 版本号白名单 ----

func TestM10RevisionIdentifierValidated(t *testing.T) {
	srv, _, _ := newM10Server(t)
	token := register(t, srv)

	badPaths := []string{
		"/api/v1/notes/bad*id/revisions",
		"/api/v1/notes/" + strings.Repeat("i", 129) + "/revisions",
		"/api/v1/notes/note-1/revisions/0",
		"/api/v1/notes/note-1/revisions/-1",
		"/api/v1/notes/note-1/revisions/abc",
	}
	for _, p := range badPaths {
		rec := authReq(srv, token, http.MethodGet, p, nil)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s 期望 400，实际 %d %s", p, rec.Code, rec.Body.String())
		}
	}

	// 合法 id + 合法版本：不因校验而回归（笔记不存在 → 404，而非 400）。
	rec := authReq(srv, token, http.MethodGet, "/api/v1/notes/note-1/revisions/1", nil)
	if rec.Code == http.StatusBadRequest {
		t.Errorf("合法标识符不应被拒：%d %s", rec.Code, rec.Body.String())
	}
}

// ---- 校验函数本身 ----

func TestM10Validators(t *testing.T) {
	good := sha256Hex([]byte("x"))
	if !validSHA256(good) {
		t.Errorf("合法 sha256 应通过：%s", good)
	}
	for _, bad := range []string{"", "abc", strings.ToUpper(good), good[:63], good + "0", strings.Repeat("z", 64)} {
		if validSHA256(bad) {
			t.Errorf("非法 sha256 应被拒：%q", bad)
		}
	}

	for _, id := range []string{"note-1", "clip-abc.def", "a_b:c", strings.Repeat("i", 128)} {
		if !validID(id) {
			t.Errorf("合法 id 应通过：%q", id)
		}
	}
	for _, bad := range []string{"", "bad id", "bad/id", "bad*id", strings.Repeat("i", 129)} {
		if validID(bad) {
			t.Errorf("非法 id 应被拒：%q", bad)
		}
	}

	for _, s := range []string{"1", "42"} {
		if _, ok := validVersion(s); !ok {
			t.Errorf("合法 version 应通过：%q", s)
		}
	}
	for _, bad := range []string{"", "0", "-1", "1.5", "abc", "99999999999999999999"} {
		if _, ok := validVersion(bad); ok {
			t.Errorf("非法 version 应被拒：%q", bad)
		}
	}
}
