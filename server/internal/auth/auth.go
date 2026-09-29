// Package auth 提供基于 Bearer token 的简单鉴权中间件。
package auth

import (
	"context"
	"net/http"
	"strings"

	"sui/note-server/internal/store"
)

type ctxKey string

const usernameKey ctxKey = "username"

// Middleware 校验 Authorization: Bearer <token>，成功则注入 username。
func Middleware(st *store.Store, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		token := strings.TrimPrefix(header, "Bearer ")
		ok, username := st.VerifyToken(token)
		if !ok {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		ctx := context.WithValue(r.Context(), usernameKey, username)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// Username 从请求上下文取已鉴权的用户名。
func Username(r *http.Request) string {
	if v, ok := r.Context().Value(usernameKey).(string); ok {
		return v
	}
	return ""
}
