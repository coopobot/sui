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
			ID       string `json:"id"`
			Accepted bool   `json:"accepted"`
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
			ID            string `json:"id"`
			Accepted      bool   `json:"accepted"`
			ServerVersion int    `json:"serverVersion"`
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

func TestAttachmentMappingSync(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	type attJSON struct {
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

	push := func(base int, atts []attJSON) {
		t.Helper()
		body, _ := json.Marshal(map[string]any{
			"clientId": "dev-a", "items": []map[string]any{
				{
					"id": "note-a1", "title": "带附件的笔记", "content": "![](sui://sha1)",
					"baseVersion": base, "version": base + 1, "sourceDevice": "dev-a",
					"attachments": atts,
				},
			},
		})
		rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", body)
		if rec.Code != http.StatusOK {
			t.Fatalf("push failed: %d %s", rec.Code, rec.Body.String())
		}
		var resp struct {
			Results []struct {
				Accepted bool `json:"accepted"`
			} `json:"results"`
		}
		if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.Results) != 1 || !resp.Results[0].Accepted {
			t.Fatalf("expected accepted, got %+v", resp.Results)
		}
	}

	// 1) 首次推送：笔记 + 一个附件映射 → 引用计数 +1
	push(0, []attJSON{{
		ID: "att-1", Filename: "图.png", MimeKind: "image",
		ByteSize: 2048, SHA256: "sha1", StorageRef: "sha1",
		EmbeddedPos: 0, CreatedAt: "2026-01-01T00:00:00Z",
	}})

	n, err := srv.store.BlobRefCount("sha1")
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("expected refcount=1 after first push, got %d", n)
	}

	// 另一台设备 pull → 拿到笔记与其附件映射
	rec := authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("pull failed: %d", rec.Code)
	}
	var pullResp struct {
		Notes []struct {
			ID          string    `json:"id"`
			Attachments []attJSON `json:"attachments"`
		} `json:"notes"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&pullResp); err != nil {
		t.Fatal(err)
	}
	if len(pullResp.Notes) != 1 || len(pullResp.Notes[0].Attachments) != 1 {
		t.Fatalf("expected 1 note with 1 attachment, got %+v", pullResp.Notes)
	}
	got := pullResp.Notes[0].Attachments[0]
	if got.ID != "att-1" || got.SHA256 != "sha1" || got.Filename != "图.png" || got.ByteSize != 2048 {
		t.Fatalf("unexpected attachment payload: %+v", got)
	}

	// 2) 重复推送同一映射（幂等）→ 引用计数仍为 1，不重复累加
	push(1, []attJSON{{
		ID: "att-1", Filename: "图.png", MimeKind: "image",
		ByteSize: 2048, SHA256: "sha1", StorageRef: "sha1",
	}})
	if n, _ = srv.store.BlobRefCount("sha1"); n != 1 {
		t.Fatalf("expected refcount=1 after idempotent re-push, got %d", n)
	}

	// 3) 同一映射改指另一个 blob → 旧 -1、新 +1
	push(2, []attJSON{{
		ID: "att-1", Filename: "图.png", MimeKind: "image",
		ByteSize: 4096, SHA256: "sha2", StorageRef: "sha2",
	}})
	if n, _ = srv.store.BlobRefCount("sha1"); n != 0 {
		t.Fatalf("expected refcount=0 for old blob, got %d", n)
	}
	if n, _ = srv.store.BlobRefCount("sha2"); n != 1 {
		t.Fatalf("expected refcount=1 for new blob, got %d", n)
	}

	// 4) 墓碑化附件 → 引用计数归零，且 pull 能带回墓碑（供对端收敛删除）
	push(3, []attJSON{{
		ID: "att-1", Filename: "图.png", MimeKind: "image",
		ByteSize: 4096, SHA256: "sha2", StorageRef: "sha2", IsDeleted: true,
	}})
	if n, _ = srv.store.BlobRefCount("sha2"); n != 0 {
		t.Fatalf("expected refcount=0 after tombstone, got %d", n)
	}

	rec = authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
	pullResp.Notes = nil
	if err := json.NewDecoder(rec.Body).Decode(&pullResp); err != nil {
		t.Fatal(err)
	}
	if len(pullResp.Notes) != 1 || len(pullResp.Notes[0].Attachments) != 1 {
		t.Fatalf("expected tombstoned attachment still listed, got %+v", pullResp.Notes)
	}
	if !pullResp.Notes[0].Attachments[0].IsDeleted {
		t.Fatal("expected isDeleted=true on tombstoned attachment")
	}

	// 5) 孤儿 blob 可被 GC 回收（refcount=0）
	orphans, err := srv.store.GCOrphanBlobs()
	if err != nil {
		t.Fatal(err)
	}
	has := func(hash string) bool {
		for _, h := range orphans {
			if h == hash {
				return true
			}
		}
		return false
	}
	if !has("sha1") || !has("sha2") {
		t.Fatalf("expected both orphan blobs collected, got %v", orphans)
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

func TestSyncNotebookTagPayload(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	// 推送：一条笔记本分组、一条标签，以及一篇携带 tagIds 的笔记。
	pushBody, _ := json.Marshal(map[string]any{
		"clientId": "dev-a",
		"notebooks": []map[string]any{
			{"id": "nb-1", "parentId": "", "name": "工作", "sortOrder": 1, "baseVersion": 0, "version": 1, "sourceDevice": "dev-a"},
		},
		"tags": []map[string]any{
			{"id": "tag-1", "name": "重要", "baseVersion": 0, "version": 1, "sourceDevice": "dev-a"},
		},
		"items": []map[string]any{
			{
				"id": "note-1", "title": "Hello", "content": "# Hi",
				"baseVersion": 0, "version": 1, "sourceDevice": "dev-a",
				"notebookId": "nb-1",
				"tagIds":     []string{"tag-1"},
			},
		},
	})
	rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", pushBody)
	if rec.Code != http.StatusOK {
		t.Fatalf("push failed: %d %s", rec.Code, rec.Body.String())
	}
	var pushResp struct {
		NotebookResults []struct {
			ID       string `json:"id"`
			Accepted bool   `json:"accepted"`
		} `json:"notebookResults"`
		TagResults []struct {
			ID       string `json:"id"`
			Accepted bool   `json:"accepted"`
		} `json:"tagResults"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&pushResp); err != nil {
		t.Fatal(err)
	}
	if len(pushResp.NotebookResults) != 1 || !pushResp.NotebookResults[0].Accepted {
		t.Fatalf("notebook push not accepted: %+v", pushResp.NotebookResults)
	}
	if len(pushResp.TagResults) != 1 || !pushResp.TagResults[0].Accepted {
		t.Fatalf("tag push not accepted: %+v", pushResp.TagResults)
	}

	type pullBody struct {
		Notes []struct {
			ID         string   `json:"id"`
			Version    int      `json:"version"`
			NotebookID string   `json:"notebookId"`
			TagIDs     []string `json:"tagIds"`
		} `json:"notes"`
		Notebooks []struct {
			ID        string  `json:"id"`
			ParentID  *string `json:"parentId"`
			Name      string  `json:"name"`
			Version   int     `json:"version"`
			IsDeleted bool    `json:"isDeleted"`
		} `json:"notebooks"`
		Tags []struct {
			ID        string `json:"id"`
			Name      string `json:"name"`
			Version   int    `json:"version"`
			IsDeleted bool   `json:"isDeleted"`
		} `json:"tags"`
	}
	pull := func() pullBody {
		rec := authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("pull failed: %d", rec.Code)
		}
		var pb pullBody
		if err := json.NewDecoder(rec.Body).Decode(&pb); err != nil {
			t.Fatal(err)
		}
		return pb
	}

	got := pull()
	if len(got.Notebooks) != 1 || got.Notebooks[0].Name != "工作" || got.Notebooks[0].Version != 1 {
		t.Fatalf("unexpected notebooks: %+v", got.Notebooks)
	}
	// BUG5：根级笔记本不得输出 parentId（应为省略）。
	if got.Notebooks[0].ParentID != nil {
		t.Fatalf("root notebook parentId must be omitted, got %q", *got.Notebooks[0].ParentID)
	}
	if len(got.Tags) != 1 || got.Tags[0].Name != "重要" || got.Tags[0].Version != 1 {
		t.Fatalf("unexpected tags: %+v", got.Tags)
	}
	if len(got.Notes) != 1 || len(got.Notes[0].TagIDs) != 1 || got.Notes[0].TagIDs[0] != "tag-1" {
		t.Fatalf("unexpected note tagIds: %+v", got.Notes)
	}
	if got.Notes[0].NotebookID != "nb-1" {
		t.Fatalf("expected notebookId=nb-1, got %q", got.Notes[0].NotebookID)
	}

	// 笔记本以过期 base 推送 → 冲突，服务端不覆盖。
	conflictBody, _ := json.Marshal(map[string]any{
		"clientId": "dev-b",
		"notebooks": []map[string]any{
			{"id": "nb-1", "name": "改名", "baseVersion": 0, "version": 1, "sourceDevice": "dev-b"},
		},
	})
	rec = authReq(srv, token, http.MethodPost, "/api/v1/sync/push", conflictBody)
	var conflictResp struct {
		NotebookResults []struct {
			Accepted      bool `json:"accepted"`
			ServerVersion int  `json:"serverVersion"`
		} `json:"notebookResults"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&conflictResp); err != nil {
		t.Fatal(err)
	}
	if len(conflictResp.NotebookResults) != 1 || conflictResp.NotebookResults[0].Accepted ||
		conflictResp.NotebookResults[0].ServerVersion != 1 {
		t.Fatalf("expected notebook conflict on serverVersion=1, got %+v", conflictResp.NotebookResults)
	}

	// 显式空 tagIds 清空关联；同时给标签打墓碑。
	clearBody, _ := json.Marshal(map[string]any{
		"clientId": "dev-a",
		"items": []map[string]any{
			{"id": "note-1", "title": "Hello", "content": "# Hi", "baseVersion": 1, "version": 2, "sourceDevice": "dev-a", "tagIds": []string{}},
		},
		"tags": []map[string]any{
			{"id": "tag-1", "name": "重要", "baseVersion": 1, "version": 2, "isDeleted": true, "sourceDevice": "dev-a"},
		},
	})
	rec = authReq(srv, token, http.MethodPost, "/api/v1/sync/push", clearBody)
	if rec.Code != http.StatusOK {
		t.Fatalf("clear push failed: %d", rec.Code)
	}
	got = pull()
	if len(got.Notes) != 1 || len(got.Notes[0].TagIDs) != 0 {
		t.Fatalf("expected tagIds cleared, got %+v", got.Notes)
	}
	if len(got.Tags) != 1 || !got.Tags[0].IsDeleted {
		t.Fatalf("expected tag tombstone, got %+v", got.Tags)
	}
}

// login 用指定凭据登录并返回 token。
func login(t *testing.T, srv *Server, username, password string) string {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": username, "password": password})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/login", bytes.NewReader(body))
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("login failed: %d %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	return resp.Token
}

// 回归：一个用户可持有多个会话，新登录不使旧会话失效（多 profile 同时在线）。
func TestMultiSessionConcurrent(t *testing.T) {
	srv := newTestServer(t)
	tokenA := register(t, srv)          // 注册签发会话 A
	tokenB := login(t, srv, "u1", "pw") // 第二次登录 → 会话 B
	if tokenA == tokenB {
		t.Fatal("expected distinct session tokens per login")
	}

	ping := func(tok string) int {
		return authReq(srv, tok, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil).Code
	}
	if code := ping(tokenA); code != http.StatusOK {
		t.Fatalf("session A offline after second login: %d", code)
	}
	if code := ping(tokenB); code != http.StatusOK {
		t.Fatalf("session B offline: %d", code)
	}

	tokenC := login(t, srv, "u1", "pw")
	if code := ping(tokenA); code != http.StatusOK {
		t.Fatalf("session A offline after third login: %d", code)
	}
	if code := ping(tokenC); code != http.StatusOK {
		t.Fatalf("session C offline: %d", code)
	}
}

// 回归：登出仅吊销当前会话，其他会话不受影响。
func TestLogoutRevokesCurrentSession(t *testing.T) {
	srv := newTestServer(t)
	tokenA := register(t, srv)
	tokenB := login(t, srv, "u1", "pw")

	if rec := authReq(srv, tokenA, http.MethodPost, "/api/v1/logout", nil); rec.Code != http.StatusOK {
		t.Fatalf("logout failed: %d %s", rec.Code, rec.Body.String())
	}
	if rec := authReq(srv, tokenA, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for revoked session A, got %d", rec.Code)
	}
	if rec := authReq(srv, tokenB, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil); rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for session B, got %d", rec.Code)
	}
}

func TestSyncArchivedFlag(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	push := func(base int, archived bool) {
		t.Helper()
		body, _ := json.Marshal(map[string]any{
			"clientId": "dev-a", "items": []map[string]any{
				{"id": "note-arc", "title": "归档测试", "content": "c",
					"baseVersion": base, "version": base + 1, "sourceDevice": "dev-a",
					"archived": archived},
			},
		})
		rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", body)
		if rec.Code != http.StatusOK {
			t.Fatalf("push failed: %d %s", rec.Code, rec.Body.String())
		}
	}

	pullArchived := func() (bool, bool) {
		rec := authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("pull failed: %d", rec.Code)
		}
		var resp struct {
			Notes []struct {
				ID        string `json:"id"`
				Archived  bool   `json:"archived"`
				IsDeleted bool   `json:"isDeleted"`
			} `json:"notes"`
		}
		if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.Notes) != 1 {
			t.Fatalf("expected 1 note, got %+v", resp.Notes)
		}
		return resp.Notes[0].Archived, resp.Notes[0].IsDeleted
	}

	// 归档 → 服务端持久化并随 pull 下发
	push(0, true)
	if archived, deleted := pullArchived(); !archived || deleted {
		t.Fatalf("expected archived=true, isDeleted=false; got %v/%v", archived, deleted)
	}

	// 取消归档（还原）→ 状态可逆
	push(1, false)
	if archived, _ := pullArchived(); archived {
		t.Fatal("expected archived=false after unarchive")
	}
}

func TestSyncNotebookCreateRename(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	pushNb := func(base int, name string, isDeleted bool) int {
		t.Helper()
		body, _ := json.Marshal(map[string]any{
			"clientId": "dev-a", "notebooks": []map[string]any{
				{"id": "nb-x", "parentId": "", "name": name, "sortOrder": 0,
					"baseVersion": base, "version": base + 1, "isDeleted": isDeleted,
					"sourceDevice": "dev-a"},
			},
		})
		rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", body)
		if rec.Code != http.StatusOK {
			t.Fatalf("notebook push failed: %d %s", rec.Code, rec.Body.String())
		}
		var resp struct {
			NotebookResults []struct {
				Accepted       bool `json:"accepted"`
				AppliedVersion int  `json:"appliedVersion"`
			} `json:"notebookResults"`
		}
		if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.NotebookResults) != 1 || !resp.NotebookResults[0].Accepted {
			t.Fatalf("notebook push not accepted: %+v", resp.NotebookResults)
		}
		return resp.NotebookResults[0].AppliedVersion
	}

	pullNb := func() (string, int, bool) {
		rec := authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("pull failed: %d", rec.Code)
		}
		var resp struct {
			Notebooks []struct {
				Name      string `json:"name"`
				Version   int    `json:"version"`
				IsDeleted bool   `json:"isDeleted"`
			} `json:"notebooks"`
		}
		if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
			t.Fatal(err)
		}
		if len(resp.Notebooks) != 1 {
			t.Fatalf("expected 1 notebook, got %+v", resp.Notebooks)
		}
		return resp.Notebooks[0].Name, resp.Notebooks[0].Version, resp.Notebooks[0].IsDeleted
	}

	// 新建笔记本 → 上行并落库（FR-29 服务端侧）
	if v := pushNb(0, "工作", false); v != 1 {
		t.Fatalf("expected appliedVersion=1 on create, got %d", v)
	}
	if name, ver, del := pullNb(); name != "工作" || ver != 1 || del {
		t.Fatalf("unexpected notebook after create: %s/%d/%v", name, ver, del)
	}

	// 重命名 → 版本收敛
	if v := pushNb(1, "工作总结", false); v != 2 {
		t.Fatalf("expected appliedVersion=2 on rename, got %d", v)
	}
	if name, ver, _ := pullNb(); name != "工作总结" || ver != 2 {
		t.Fatalf("unexpected notebook after rename: %s/%d", name, ver)
	}

	// 删除 → 墓碑下发（客户端据此收敛；笔记进回收站为客户端语义）
	if v := pushNb(2, "工作总结", true); v != 3 {
		t.Fatalf("expected appliedVersion=3 on delete, got %d", v)
	}
	if _, _, del := pullNb(); !del {
		t.Fatal("expected notebook tombstone after delete")
	}
}
