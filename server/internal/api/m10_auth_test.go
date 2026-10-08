package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

// M10-T31：令牌签发 / 刷新 / 撤销 / 过期拒绝（auth.md §8，AC-156~AC-159）。
//
// 门禁要点：
//   - 登录 / 注册签发**双令牌**且访问令牌短时有效；
//   - 访问令牌过期 → `token-expired`（客户端可透明刷新），坏令牌 → `invalid_token`；
//   - 刷新**轮换 + 单次使用**；旧刷新令牌被重放 → **吊销整个会话**（`refresh-revoked`）；
//   - `logout` 只吊销当前会话，`logout-all` 吊销全部会话；撤销即时生效（含关闭 WS 连接）。

const protectedPath = "/api/v1/sync/pull?since=1970-01-01T00:00:00Z"

type tokenPairResp struct {
	OK           bool   `json:"ok"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
}

// issuePair 走 POST /api/v1/register 签发双令牌（首启建号）。
func issuePair(t *testing.T, srv *Server) tokenPairResp {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": "u1", "password": "pw"})
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/register", bytes.NewReader(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("register failed: %d %s", rec.Code, rec.Body.String())
	}
	return pairFrom(t, rec)
}

// loginPair 走 POST /api/v1/login 追加一个新会话并返回其双令牌。
func loginPair(t *testing.T, srv *Server, username, password string) tokenPairResp {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": username, "password": password})
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/login", bytes.NewReader(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("login failed: %d %s", rec.Code, rec.Body.String())
	}
	return pairFrom(t, rec)
}

func pairFrom(t *testing.T, rec *httptest.ResponseRecorder) tokenPairResp {
	t.Helper()
	var out tokenPairResp
	if err := json.NewDecoder(rec.Body).Decode(&out); err != nil {
		t.Fatalf("decode token pair: %v", err)
	}
	return out
}

func refreshWith(srv *Server, refreshToken string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"refresh_token": refreshToken})
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/refresh", bytes.NewReader(body)))
	return rec
}

func errorCodeOf(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var out struct {
		Error string `json:"error"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&out); err != nil {
		t.Fatalf("decode error body: %v", err)
	}
	return out.Error
}

func protectedStatus(srv *Server, token string) int {
	return authReq(srv, token, http.MethodGet, protectedPath, nil).Code
}

// 注册与登录都签发「访问 + 刷新」双令牌，响应不再暴露单一永久 token。
func TestM10IssueTokenPair(t *testing.T) {
	srv := newTestServer(t)

	pair := issuePair(t, srv)
	if pair.AccessToken == "" || pair.RefreshToken == "" {
		t.Fatalf("注册应签发双令牌，实际 %+v", pair)
	}
	if pair.AccessToken == pair.RefreshToken {
		t.Error("访问令牌与刷新令牌不应相同")
	}
	if pair.ExpiresIn <= 0 || pair.ExpiresIn > 31*60 {
		t.Errorf("expires_in 应在 (0, 30min]，实际 %d", pair.ExpiresIn)
	}
	if code := protectedStatus(srv, pair.AccessToken); code != http.StatusOK {
		t.Errorf("访问令牌应可访问受保护接口，实际 %d", code)
	}

	login := loginPair(t, srv, "u1", "pw")
	if login.AccessToken == "" || login.RefreshToken == "" {
		t.Errorf("登录应签发双令牌，实际 %+v", login)
	}
	if login.AccessToken == pair.AccessToken {
		t.Error("新登录应签发新会话（多设备模型）")
	}
	// 旧会话不受影响
	if code := protectedStatus(srv, pair.AccessToken); code != http.StatusOK {
		t.Errorf("新登录不应影响既有会话，实际 %d", code)
	}
}

// 访问令牌过期 → 401 token-expired（可刷新）；刷新后新访问令牌可用、旧访问令牌即失效。
func TestM10AccessTokenExpiryAndRefresh(t *testing.T) {
	srv := newTestServer(t)
	t.Setenv("SUI_ACCESS_TTL", "1ns")
	pair := issuePair(t, srv)

	rec := authReq(srv, pair.AccessToken, http.MethodGet, protectedPath, nil)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("过期访问令牌应 401，实际 %d %s", rec.Code, rec.Body.String())
	}
	if got := errorCodeOf(t, rec); got != "token-expired" {
		t.Errorf("错误码应为 token-expired（客户端据此透明刷新），实际 %q", got)
	}

	// 放宽 TTL 后刷新：新访问令牌立即可用
	t.Setenv("SUI_ACCESS_TTL", "1h")
	rec = refreshWith(srv, pair.RefreshToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("刷新应成功，实际 %d %s", rec.Code, rec.Body.String())
	}
	next := pairFrom(t, rec)
	if next.AccessToken == pair.AccessToken || next.RefreshToken == pair.RefreshToken {
		t.Error("刷新应换发全新的 access / refresh")
	}
	if code := protectedStatus(srv, next.AccessToken); code != http.StatusOK {
		t.Errorf("刷新后的访问令牌应可用，实际 %d", code)
	}
	// 轮换即换号：会话行只保留最新访问令牌哈希（auth.md §8.3）
	if code := protectedStatus(srv, pair.AccessToken); code != http.StatusUnauthorized {
		t.Errorf("轮换后旧访问令牌应失效，实际 %d", code)
	}
}

// 刷新轮换 + 单次使用：旧刷新令牌被重放 → 判定泄露 → 吊销整个会话。
func TestM10RefreshRotationAndReplayRevokes(t *testing.T) {
	srv := newTestServer(t)
	pair := issuePair(t, srv)

	rec := refreshWith(srv, pair.RefreshToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("首次刷新应成功，实际 %d %s", rec.Code, rec.Body.String())
	}
	next := pairFrom(t, rec)
	if code := protectedStatus(srv, next.AccessToken); code != http.StatusOK {
		t.Fatalf("轮换后的访问令牌应可用，实际 %d", code)
	}

	// 重放已被换发的刷新令牌
	rec = refreshWith(srv, pair.RefreshToken)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("重放旧刷新令牌应 401，实际 %d %s", rec.Code, rec.Body.String())
	}
	if got := errorCodeOf(t, rec); got != "refresh-revoked" {
		t.Errorf("错误码应为 refresh-revoked，实际 %q", got)
	}

	// 会话已被整体吊销：轮换后的访问令牌与刷新令牌都失效（fail-safe）
	if code := protectedStatus(srv, next.AccessToken); code != http.StatusUnauthorized {
		t.Errorf("重放吊销后访问令牌应 401，实际 %d", code)
	}
	rec = refreshWith(srv, next.RefreshToken)
	if rec.Code != http.StatusUnauthorized || errorCodeOf(t, rec) != "refresh-revoked" {
		t.Errorf("重放吊销后刷新应 401 refresh-revoked，实际 %d %s", rec.Code, rec.Body.String())
	}
}

// 刷新令牌自然过期 → 401 refresh-expired（不额外吊销；访问令牌若未过期仍可用）。
func TestM10RefreshExpiredCode(t *testing.T) {
	srv := newTestServer(t)
	t.Setenv("SUI_REFRESH_TTL", "1ms")
	pair := issuePair(t, srv)
	time.Sleep(5 * time.Millisecond) // 让刷新令牌真正过期

	rec := refreshWith(srv, pair.RefreshToken)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("过期刷新令牌应 401，实际 %d %s", rec.Code, rec.Body.String())
	}
	if got := errorCodeOf(t, rec); got != "refresh-expired" {
		t.Errorf("错误码应为 refresh-expired，实际 %q", got)
	}
	if code := protectedStatus(srv, pair.AccessToken); code != http.StatusOK {
		t.Errorf("刷新令牌过期不应连带吊销会话（访问令牌未过期），实际 %d", code)
	}
}

// 坏令牌 / 缺头 → 401 invalid_token（与 token-expired 可区分）。
func TestM10InvalidTokenCode(t *testing.T) {
	srv := newTestServer(t)
	issuePair(t, srv)

	rec := authReq(srv, strings.Repeat("ab", 32), http.MethodGet, protectedPath, nil)
	if rec.Code != http.StatusUnauthorized || errorCodeOf(t, rec) != "invalid_token" {
		t.Fatalf("坏令牌应 401 invalid_token，实际 %d %s", rec.Code, rec.Body.String())
	}

	rec = httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, protectedPath, nil))
	if rec.Code != http.StatusUnauthorized || errorCodeOf(t, rec) != "invalid_token" {
		t.Fatalf("缺 Authorization 头应 401 invalid_token，实际 %d %s", rec.Code, rec.Body.String())
	}
}

// logout-all 吊销该用户全部会话（含另一设备的会话）；logout 只吊销当前会话。
func TestM10LogoutAllRevokesEverySession(t *testing.T) {
	srv := newTestServer(t)
	a := issuePair(t, srv)
	b := loginPair(t, srv, "u1", "pw")

	if code := protectedStatus(srv, b.AccessToken); code != http.StatusOK {
		t.Fatalf("会话 B 应可用，实际 %d", code)
	}

	rec := authReq(srv, a.AccessToken, http.MethodPost, "/api/v1/logout-all", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("logout-all 应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Revoked int `json:"revoked"`
	}
	_ = json.NewDecoder(rec.Body).Decode(&out)
	if out.Revoked < 2 {
		t.Errorf("应吊销至少 2 个会话，实际 %d", out.Revoked)
	}
	for name, tok := range map[string]string{"A": a.AccessToken, "B": b.AccessToken} {
		if code := protectedStatus(srv, tok); code != http.StatusUnauthorized {
			t.Errorf("logout-all 后会话 %s 应 401，实际 %d", name, code)
		}
	}
	if rec := refreshWith(srv, b.RefreshToken); rec.Code != http.StatusUnauthorized {
		t.Errorf("logout-all 后刷新令牌应失效，实际 %d", rec.Code)
	}
}

// 撤销即时生效：登出后服务端须主动关闭该会话的 WebSocket 连接（auth.md §4.5）。
func TestM10WsClosedOnLogout(t *testing.T) {
	srv := newTestServer(t)
	pair := issuePair(t, srv)

	hs := httptest.NewServer(srv.Router())
	defer hs.Close()
	wsBase := "ws" + strings.TrimPrefix(hs.URL, "http")

	c, _, err := websocket.Dial(context.Background(), wsBase+"/api/v1/ws", &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + pair.AccessToken}},
	})
	if err != nil {
		t.Fatalf("WS 升级应成功：%v", err)
	}
	defer c.Close(websocket.StatusNormalClosure, "")

	if rec := authReq(srv, pair.AccessToken, http.MethodPost, "/api/v1/logout", nil); rec.Code != http.StatusOK {
		t.Fatalf("登出应 200，实际 %d %s", rec.Code, rec.Body.String())
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if _, _, err := c.Read(ctx); err == nil {
		t.Error("会话吊销后服务端应关闭该 WS 连接（读应报错）")
	}
}
