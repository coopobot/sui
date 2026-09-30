package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"nhooyr.io/websocket"
)

// M4/BR-33.4：ping 报告 initialized，供客户端判断是否仍可注册。
func TestPingInitialized(t *testing.T) {
	srv := newTestServer(t)
	ping := func() bool {
		rec := httptest.NewRecorder()
		srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("ping status %d", rec.Code)
		}
		var body Payload
		if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body.Msg != "pong" {
			t.Fatalf("expected msg=pong, got %q", body.Msg)
		}
		return body.Initialized
	}
	if ping() {
		t.Fatal("fresh instance should report initialized=false")
	}
	register(t, srv)
	if !ping() {
		t.Fatal("after first account should report initialized=true")
	}
}

// M4/BR-33.2：首启建号后关闭自助注册。
func TestRegisterGatewayClosed(t *testing.T) {
	srv := newTestServer(t)
	register(t, srv)

	body, _ := json.Marshal(map[string]string{"username": "u2", "password": "pw2"})
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/register", bytes.NewReader(body)))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 after first account, got %d %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Error string `json:"error"`
	}
	_ = json.NewDecoder(rec.Body).Decode(&resp)
	if resp.Error != "already-initialized" {
		t.Fatalf("expected already-initialized, got %q", resp.Error)
	}
}

// M4/BR-36.1：密码以哈希存储，错误密码被拒、正确密码可登录。
func TestLoginRejectsWrongPassword(t *testing.T) {
	srv := newTestServer(t)
	register(t, srv)

	body, _ := json.Marshal(map[string]string{"username": "u1", "password": "wrong"})
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/login", bytes.NewReader(body)))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for wrong password, got %d", rec.Code)
	}
	if tok := login(t, srv, "u1", "pw"); tok == "" {
		t.Fatal("expected token for correct password")
	}
}

// M4/BR-35.x：WS 端点须鉴权；未携带 token → 握手被拒，有效 token → 升级成功。
func TestWsAuthRequired(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	hs := httptest.NewServer(srv.Router())
	defer hs.Close()
	wsBase := "ws" + strings.TrimPrefix(hs.URL, "http")

	if c, _, err := websocket.Dial(context.Background(), wsBase+"/api/v1/ws", nil); err == nil {
		c.Close(websocket.StatusNormalClosure, "")
		t.Fatal("expected WS handshake rejection without token")
	}
	c, _, err := websocket.Dial(context.Background(), wsBase+"/api/v1/ws?token="+token, nil)
	if err != nil {
		t.Fatalf("expected WS upgrade with valid token, got %v", err)
	}
	c.Close(websocket.StatusNormalClosure, "")
}

// M4/FR-34 / AC-98：剪藏 id ≥128 bit，同 URL 幂等复用、异 URL 区分。
func TestClipIDUniqueness(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	post := func(url string) (string, int) {
		body, _ := json.Marshal(map[string]string{"url": url, "title": "T", "html": "<article><h1>H</h1><p>正文</p></article>"})
		rec := authReq(srv, token, http.MethodPost, "/api/v1/clips", body)
		if rec.Code != http.StatusOK {
			t.Fatalf("clip failed: %d %s", rec.Code, rec.Body.String())
		}
		var resp struct {
			NoteID  string `json:"noteId"`
			Version int    `json:"version"`
		}
		if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
			t.Fatal(err)
		}
		return resp.NoteID, resp.Version
	}

	id1, v1 := post("https://example.com/a")
	if !strings.HasPrefix(id1, "clip-") || len(id1)-len("clip-") < 32 {
		t.Fatalf("clip id must carry >=128-bit digest, got %q", id1)
	}
	id2, v2 := post("https://example.com/a")
	if id1 != id2 {
		t.Fatalf("same URL must reuse id: %q vs %q", id1, id2)
	}
	if v2 != v1+1 {
		t.Fatalf("expected version increment on re-clip, got %d -> %d", v1, v2)
	}
	if id3, _ := post("https://example.com/b"); id3 == id1 {
		t.Fatalf("different URL must yield different id, got %q", id3)
	}
}
