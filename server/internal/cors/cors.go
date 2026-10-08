// Package cors 提供简单的 CORS 中间件。
//
// M10-T23 / BR-52.5：**默认拒绝**——SUI_ALLOWED_ORIGINS 未配置时不再回显任意
// Origin（v0.10.x 的「开发模式全放行」已注销）。不带 Origin 的调用（同源 /
// 桌面端 / 移动端 / 浏览器扩展 / curl）不受影响。
package cors

import "net/http"

// Middleware 返回 CORS 中间件：Allow-Origin 仅来自**精确匹配**的白名单。
//
// allowedOrigins 为空 → 不写任何 Access-Control-Allow-* 头（预检仍回 204，
// 但浏览器因缺少 Allow-Origin 而拒绝跨域请求）。
func Middleware(allowedOrigins []string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowOrigin := ""
		if origin != "" {
			for _, o := range allowedOrigins {
				if o == "*" || o == origin {
					allowOrigin = origin
					break
				}
			}
		}
		if allowOrigin != "" {
			w.Header().Set("Access-Control-Allow-Origin", allowOrigin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS, HEAD")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.Header().Set("Access-Control-Expose-Headers", "Content-Length")
			w.Header().Set("Access-Control-Max-Age", "86400")
			w.Header().Set("Vary", "Origin")
		}

		// 预检请求直接返回
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}
