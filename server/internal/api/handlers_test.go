package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"sui/note-server/internal/blob"
	"sui/note-server/internal/store"
)

func newTestServer(t *testing.T) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	blobs, err := blob.NewLocal(t.TempDir())
	if err != nil {
		t.Fatalf("init blob: %v", err)
	}
	return New(st, blobs)
}

func TestPingEndpoint(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil)
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	var body Payload
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body.Msg != "pong" {
		t.Errorf("expected msg=pong, got %q", body.Msg)
	}
}

func TestHealthEndpoint(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
}

// 注册用户并返回有效 token。
func register(t *testing.T, srv *Server) string {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": "u1", "password": "pw"})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/register", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("register failed: %d %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	return resp.Token
}

func authReq(srv *Server, token, method, path string, body []byte) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	return rec
}

func TestSyncPushAndPull(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	// Push 一条新笔记（base=0）
	pushBody, _ := json.Marshal(map[string]any{
		"clientId": "dev-a",
		"items": []map[string]any{
			{
				"id": "note-1", "title": "Hello", "content": "# Hi",
				"baseVersion": 0, "version": 1, "sourceDevice": "dev-a",
			},
		},
	})
	rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", pushBody)
	if rec.Code != http.StatusOK {
		t.Fatalf("push failed: %d %s", rec.Code, rec.Body.String())
	}
	var pushResp struct {
		Results []struct {
			ID string `json:"id"`
			Accepted bool `json:"accepted"`
		} `json:"results"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&pushResp); err != nil {
		t.Fatal(err)
	}
	if len(pushResp.Results) != 1 || !pushResp.Results[0].Accepted {
		t.Fatalf("expected accepted ok, got %+v", pushResp.Results)
	}

	// Pull 应返回该笔记（含版本 1）
	rec = authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("pull failed: %d", rec.Code)
	}
	var pullResp struct {
		Notes []struct {
			ID      string `json:"id"`
			Content string `json:"content"`
			Version int    `json:"version"`
		} `json:"notes"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&pullResp); err != nil {
		t.Fatal(err)
	}
	if len(pullResp.Notes) != 1 || pullResp.Notes[0].Content != "# Hi" || pullResp.Notes[0].Version != 1 {
		t.Fatalf("unexpected pull: %+v", pullResp.Notes)
	}
}

func TestSyncConflictReturned(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	// 先提交一条（服务端版本到 1）
	pushOne := func(base, ver int) {
		body, _ := json.Marshal(map[string]any{
			"clientId": "c", "items": []map[string]any{
				{"id": "n", "title": "t", "content": "c", "baseVersion": base, "version": ver, "sourceDevice": "d"},
			},
		})
		rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", body)
		if rec.Code != http.StatusOK {
			t.Fatalf("push failed: %d", rec.Code)
		}
	}
	pushOne(0, 1) // 服务端 version=1

	// 客户端 A 以 base=0 push → 冲突（服务端已是 1）
	body, _ := json.Marshal(map[string]any{
		"clientId": "a", "items": []map[string]any{
			{"id": "n", "title": "t2", "content": "c2", "baseVersion": 0, "version": 1, "sourceDevice": "a"},
		},
	})
	rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", body)
	var resp struct {
		Results []struct {
			ID string `json:"id"`
			Accepted bool `json:"accepted"`
			ServerVersion int `json:"serverVersion"`
		} `json:"results"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if resp.Results[0].Accepted {
		t.Fatalf("expected conflict (accepted=false), got accepted")
	}
	if resp.Results[0].ServerVersion != 1 {
		t.Fatalf("expected serverVersion=1, got %d", resp.Results[0].ServerVersion)
	}
}

func TestUnauthenticatedRejected(t *testing.T) {
	srv := newTestServer(t)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/sync/push", bytes.NewReader([]byte("{}")))
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestRevisionListAndGet(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	// Push 两个版本的笔记，产生 2 条修订
	pushVer := func(base, ver int, title, content string) {
		body, _ := json.Marshal(map[string]any{
			"clientId": "dev-a", "items": []map[string]any{
				{"id": "note-r1", "title": title, "content": content,
					"baseVersion": base, "version": ver, "sourceDevice": "dev-a"},
			},
		})
		rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", body)
		if rec.Code != http.StatusOK {
			t.Fatalf("push v%d failed: %d %s", ver, rec.Code, rec.Body.String())
		}
	}
	pushVer(0, 1, "v1 标题", "v1 内容")
	pushVer(1, 2, "v2 标题", "v2 内容")

	// 列出修订
	rec := authReq(srv, token, http.MethodGet, "/api/v1/notes/note-r1/revisions", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list revisions failed: %d %s", rec.Code, rec.Body.String())
	}
	var listResp struct {
		Revisions []struct {
			Version int    `json:"version"`
			Title   string `json:"title"`
			Content string `json:"content"`
		} `json:"revisions"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&listResp); err != nil {
		t.Fatal(err)
	}
	if len(listResp.Revisions) != 2 {
		t.Fatalf("expected 2 revisions, got %d", len(listResp.Revisions))
	}
	// 按 version 降序
	if listResp.Revisions[0].Version != 2 || listResp.Revisions[0].Title != "v2 标题" {
		t.Fatalf("expected first revision v2, got %+v", listResp.Revisions[0])
	}
	if listResp.Revisions[1].Version != 1 || listResp.Revisions[1].Content != "v1 内容" {
		t.Fatalf("expected second revision v1, got %+v", listResp.Revisions[1])
	}

	// 获取单条修订
	rec = authReq(srv, token, http.MethodGet, "/api/v1/notes/note-r1/revisions/1", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("get revision failed: %d", rec.Code)
	}
	var getResp struct {
		Revision struct {
			Version int    `json:"version"`
			Title   string `json:"title"`
			Content string `json:"content"`
		} `json:"revision"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&getResp); err != nil {
		t.Fatal(err)
	}
	if getResp.Revision.Version != 1 || getResp.Revision.Title != "v1 标题" {
		t.Fatalf("unexpected revision: %+v", getResp.Revision)
	}

	// 不存在的版本返回 404
	rec = authReq(srv, token, http.MethodGet, "/api/v1/notes/note-r1/revisions/99", nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for missing revision, got %d", rec.Code)
	}
}

func TestClipEndpoint(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	html := `<!DOCTYPE html>
<html><head><title>测试文章标题</title></head>
<body>
<nav>导航链接</nav>
<article>
<h1>文章大标题</h1>
<p>这是第一段<strong>加粗文字</strong>和<em>斜体</em>。</p>
<p>第二段带<a href="https://example.com">链接</a>。</p>
<ul>
<li>列表项一</li>
<li>列表项二</li>
</ul>
<blockquote>引用文字</blockquote>
</article>
<footer>页脚版权</footer>
</body></html>`

	body, _ := json.Marshal(map[string]string{
		"url":   "https://example.com/article/123",
		"title": "",
		"html":  html,
	})
	rec := authReq(srv, token, http.MethodPost, "/api/v1/clips", body)
	if rec.Code != http.StatusOK {
		t.Fatalf("clip failed: %d %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		OK      bool   `json:"ok"`
		NoteID  string `json:"noteId"`
		Title   string `json:"title"`
		Version int    `json:"version"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if !resp.OK {
		t.Fatal("expected ok=true")
	}
	if resp.Title == "" {
		t.Fatal("expected non-empty title")
	}
	if resp.Version != 1 {
		t.Fatalf("expected version=1, got %d", resp.Version)
	}

	// 幂等：同一 URL 再次剪藏 → version 2
	rec = authReq(srv, token, http.MethodPost, "/api/v1/clips", body)
	if rec.Code != http.StatusOK {
		t.Fatalf("clip second time failed: %d", rec.Code)
	}
	var resp2 struct {
		OK      bool `json:"ok"`
		Version int  `json:"version"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&resp2); err != nil {
		t.Fatal(err)
	}
	if resp2.Version != 2 {
		t.Fatalf("expected version=2 after re-clip, got %d", resp2.Version)
	}

	// 通过 pull 验证剪藏内容已入库
	rec = authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
	var pullResp struct {
		Notes []struct {
			ID      string `json:"id"`
			Title   string `json:"title"`
			Content string `json:"content"`
		} `json:"notes"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&pullResp); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, n := range pullResp.Notes {
		if n.ID == resp.NoteID {
			found = true
			if n.Title != "测试文章标题" {
				t.Fatalf("unexpected title: %q", n.Title)
			}
			// 内容应该包含来源链接
			if !strings.Contains(n.Content, "来源") || !strings.Contains(n.Content, "example.com") {
				t.Fatalf("expected source link in content, got: %q", n.Content[:min(100, len(n.Content))])
			}
			// 应该有 Markdown 格式的标题和正文
			if !strings.Contains(n.Content, "文章大标题") {
				t.Fatalf("expected article heading in content")
			}
			break
		}
	}
	if !found {
		t.Fatal("clipped note not found in pull results")
	}
}