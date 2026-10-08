// Package auth 提供基于 Bearer 访问令牌的鉴权中间件（M10：短时访问令牌 + 可撤销刷新令牌）。
//
// 设计来源：technology/design/low-level-design/auth.md §4.3 / §8.5。
// 失败响应携带**可区分错误码**，客户端据此决策（不自行判定过期，避免端侧时钟偏差）：
//
//	token-expired  → 访问令牌过期，应调 /api/v1/refresh 后重放原请求
//	invalid_token  → 坏令牌 / 未命中 / 已吊销，须重新登录
package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"sui/note-server/internal/store"
)

type ctxKey string

const (
	usernameKey ctxKey = "username"
	sessionKey  ctxKey = "sessionID"
)

// Middleware 校验 Authorization: Bearer <访问令牌>，成功则注入 username 与 sessionID。
func Middleware(st *store.Store, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			unauthorized(w, "invalid_token")
			return
		}
		token := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
		status, username, sessionID := st.Authenticate(token)
		switch status {
		case store.AuthExpired:
			// 过期与无效必须可区分：前者客户端会透明刷新（BR-49.3）。
			unauthorized(w, "token-expired")
		case store.AuthOK:
			ctx := context.WithValue(r.Context(), usernameKey, username)
			ctx = context.WithValue(ctx, sessionKey, sessionID)
			next.ServeHTTP(w, r.WithContext(ctx))
		default:
			unauthorized(w, "invalid_token")
		}
	})
}

// unauthorized 回 JSON 错误体（与 api 包口径一致：ok=false + error 码）。
func unauthorized(w http.ResponseWriter, code string) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusUnauthorized)
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": code})
}

// Username 从请求上下文取已鉴权的用户名。
func Username(r *http.Request) string {
	if v, ok := r.Context().Value(usernameKey).(string); ok {
		return v
	}
	return ""
}

// SessionID 从请求上下文取当前会话 id（供吊销后关闭其 WebSocket 连接）。
func SessionID(r *http.Request) string {
	if v, ok := r.Context().Value(sessionKey).(string); ok {
		return v
	}
	return ""
}

// BearerToken 取请求携带的访问令牌明文（登出需按令牌定位会话）。
func BearerToken(r *http.Request) string {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
}
