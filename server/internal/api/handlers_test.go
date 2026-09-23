package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
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