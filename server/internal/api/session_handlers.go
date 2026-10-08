package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"sui/note-server/internal/auth"
	"sui/note-server/internal/store"
)

// tokenResponse 组装双令牌响应体（auth.md §8.2 / §8.3）。
//
// 明文令牌只在此处出现一次；库中只有 sha256 哈希（BR-49.4）。
func tokenResponse(p *store.TokenPair, username string) map[string]any {
	out := map[string]any{
		"ok":            true,
		"access_token":  p.AccessToken,
		"refresh_token": p.RefreshToken,
		"expires_in":    p.ExpiresIn(),
	}
	if username != "" {
		out["username"] = username
	}
	return out
}

// handleRefresh 以刷新令牌轮换出新的双令牌（§8.3：单次使用；重放即吊销整个会话）。
//
// 该端点**不受** auth 中间件保护——访问令牌可能已过期，凭刷新令牌本身鉴权。
func (s *Server) handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RefreshToken string `json:"refresh_token"`
	}
	body := http.MaxBytesReader(w, r.Body, maxRefreshBodyBytes())
	if err := json.NewDecoder(body).Decode(&req); err != nil {
		if isTooLarge(err) {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]any{"ok": false, "error": "payload too large"})
			return
		}
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "bad request"})
		return
	}

	pair, err := s.store.RefreshSession(strings.TrimSpace(req.RefreshToken))
	if err != nil {
		var revoked *store.RefreshRevokedError
		switch {
		case errors.As(err, &revoked):
			// 重放 / 已吊销：会话已被整体吊销 → 立即关闭其 WebSocket 连接（§4.5）。
			s.hub.CloseSession(revoked.SessionID)
			writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "refresh-revoked"})
		case errors.Is(err, store.ErrRefreshExpired):
			writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "refresh-expired"})
		default:
			writeInternalError(w, r, err)
		}
		return
	}
	writeJSON(w, http.StatusOK, tokenResponse(pair, ""))
}

// handleLogout 吊销当前请求所用访问令牌所属会话（§8.4），并关闭其 WebSocket 连接。
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	sessionID, err := s.store.RevokeSessionByAccess(auth.BearerToken(r))
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	closed := s.hub.CloseSession(sessionID)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "closedConnections": closed})
}

// handleLogoutAll 吊销该用户**全部**会话（换机 / 失窃止损，§8.4）。
func (s *Server) handleLogoutAll(w http.ResponseWriter, r *http.Request) {
	username := auth.Username(r)
	if username == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "invalid_token"})
		return
	}
	ids, err := s.store.RevokeAllSessions(username)
	if err != nil {
		writeInternalError(w, r, err)
		return
	}
	closed := s.hub.CloseSession(ids...)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "revoked": len(ids), "closedConnections": closed,
	})
}
