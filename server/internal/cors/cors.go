// Package cors 提供简单的 CORS 中间件。
//
// M10-T23 / BR-52.5：**默认拒绝**——SUI_ALLOWED_ORIGINS 未配置时不再回显任意
// Origin（v0.10.x 的「开发模式全放行」已注销）。不带 Origin 的调用（同源 /
// 桌面端 / 移动端 / 浏览器扩展 / curl）不受影响。
//
// v0.11.2 补充（M10-T27 跨源适配）：受保护通道会给请求加**自定义头**、并在响应里回一个
// **标记头**，跨源（Flutter Web）必须分别列入 Allow-Headers / Expose-Headers：
//   - 少列请求头 → 预检被拒，Web 端根本发不出加密请求；
//   - 少列响应头 → JS 读不到 `X-Sui-Enc`，会把**密文当明文**解析（静默错位）。
package cors

import (
	"net/http"
	"strings"
)

// 受保护通道（M10-T27 / FR-50，auth.md §9.6）的请求头与响应标记头。
const (
	headerChanEnc   = "X-Sui-Enc"
	headerChanEph   = "X-Sui-Eph"
	headerChanReqID = "X-Sui-Req-Id"
)

// allowHeaders 为预检放行的请求头白名单。**显式列举**而非 `*`：`*` 在带凭证的请求下无效，
// 且会让将来新增的头「悄悄」被放行。
var allowHeaders = strings.Join([]string{
	"Content-Type", "Authorization",
	headerChanEnc, headerChanEph, headerChanReqID,
}, ", ")

// exposeHeaders 为允许 JS 读取的响应头。`X-Sui-Enc` 必须在内——否则 Web 端看不到
// 「本次响应是密文」这一标记。
var exposeHeaders = strings.Join([]string{"Content-Length", headerChanEnc}, ", ")

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
			w.Header().Set("Access-Control-Allow-Headers", allowHeaders)
			w.Header().Set("Access-Control-Expose-Headers", exposeHeaders)
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
