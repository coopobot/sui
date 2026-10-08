// Package api assembles the HTTP routing for the Sui server.
package api

import (
	"net/http"
	"net/url"
	"os"
	"strings"

	"sui/note-server/internal/auth"
	"sui/note-server/internal/blob"
	"sui/note-server/internal/cors"
	"sui/note-server/internal/securechan"
	"sui/note-server/internal/store"
	"sui/note-server/internal/sync"
	"sui/note-server/internal/ws"
)

// Server 持有所需依赖，并将 API 路由注册到 mux。
type Server struct {
	store *store.Store
	blobs blob.Store
	sync  *sync.Protocol
	hub   *ws.Hub
	// mediaClient 供剪藏媒体本地化使用；nil → 由 clip 包使用带**出网地址闸门**的默认客户端
	// （M10-T27）。仅测试会注入不带闸门的客户端。
	mediaClient *http.Client
	// chanKey 是**受保护通道**的服务端长期密钥（M10-T27 / FR-50，auth.md §9）。
	// nil = 通道未启用：握手返回 503，加密请求一律拒绝，**明文请求照常**（通道是加成而非强制）。
	chanKey *securechan.Key
}

// New 创建带依赖的 API Server。
func New(st *store.Store, blobs blob.Store) *Server {
	return &Server{
		store: st,
		blobs: blobs,
		sync:  sync.New(st),
		hub:   ws.NewHub(),
	}
}

// Hub 返回 WebSocket 集线器（供内部触发通知用）。
func (s *Server) Hub() *ws.Hub { return s.hub }

// SetMediaClient 注入剪藏媒体下载客户端。
//
// **仅供测试**：生产默认走 clip 包内带出网地址闸门的客户端（M10-T27 / clip/guard.go），
// 既有媒体用例用 127.0.0.1 的 httptest 服务器供图，必须显式注入不带闸门的客户端。
func (s *Server) SetMediaClient(c *http.Client) { s.mediaClient = c }

// SetChannelKey 注入受保护通道的服务端长期密钥（M10-T27 / FR-50）。
//
// 生产由 `cmd/sui-server` 从 `<SUI_DATA>/securechan.key` 加载或首次生成；**测试**可注入内存密钥。
func (s *Server) SetChannelKey(k *securechan.Key) { s.chanKey = k }

// Router 返回根 mux：CORS 包裹 + 公开路由 + 受保护路由。
func (s *Server) Router() http.Handler {
	// M10-T23 / BR-52.5：CORS 与 WebSocket 共用同一份来源白名单；
	// 未配置（nil）时 CORS 不回任何 Allow-* 头、WS 只接受同源 Origin。
	origins := allowedOrigins()
	s.hub.SetOriginPatterns(wsOriginPatterns(origins))

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealth)
	mux.HandleFunc("GET /api/v1/ping", s.handlePing)
	// M10-T27 / FR-50：受保护通道握手（公开；返回服务端长期公钥 + 指纹，供 TOFU 核对，§9.2）。
	mux.HandleFunc("GET /api/v1/crypto/handshake", s.handleHandshake)

	// 含**敏感正文**（口令 / 令牌）的公开端点也过通道中间件：客户端声明加密时解封请求、加密响应；
	// 未声明（`X-Sui-Enc` 缺失）则原样透传——通道是**加成**而非强制（§9.6）。
	secure := func(h http.Handler) http.Handler {
		if s.chanKey == nil {
			return h
		}
		return securechan.Middleware(s.chanKey, h)
	}
	mux.Handle("POST /api/v1/register", secure(http.HandlerFunc(s.handleRegister)))
	mux.Handle("POST /api/v1/login", secure(http.HandlerFunc(s.handleLogin)))
	// 刷新端点**不**经 auth 中间件：访问令牌可能已过期，凭刷新令牌本身鉴权（§8.3）。
	mux.Handle("POST /api/v1/refresh", secure(http.HandlerFunc(s.handleRefresh)))

	// WebSocket 端点（M4/BR-35.x：须鉴权，未通过 → 401）
	mux.HandleFunc("GET /api/v1/ws", s.handleWS)

	// 受保护路由挂载在同一 mux 下，交由 auth 中间件包裹。
	root := NewRouter(s)
	authWrap := auth.Middleware(s.store, root)
	mux.Handle("/api/v1/sync/push", secure(authWrap))
	mux.Handle("/api/v1/sync/pull", secure(authWrap))
	mux.Handle("/api/v1/blobs/", secure(authWrap))
	mux.Handle("/api/v1/notes/", secure(authWrap))
	mux.Handle("/api/v1/clips", secure(authWrap))
	mux.Handle("/api/v1/logout", secure(authWrap))
	mux.Handle("/api/v1/logout-all", secure(authWrap))

	// CORS 中间件包裹最外层（M4/BR-36.3 + M10-T23：白名单精确匹配；未配置 = 默认拒绝）
	return cors.Middleware(origins, mux)
}

// allowedOrigins 解析 SUI_ALLOWED_ORIGINS（逗号分隔）；为空返回 nil。
//
// M10-T23：nil = **默认拒绝**（不再回显任意 Origin，见 input-validation.md §6）。
func allowedOrigins() []string {
	raw := strings.TrimSpace(os.Getenv("SUI_ALLOWED_ORIGINS"))
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// handleHandshake 返回服务端长期通道公钥与指纹（M10-T27 / FR-50，auth.md §9.2 / §9.6）。
//
// 无需令牌：它是**信任根分发**入口（TOFU），不含任何秘密。
func (s *Server) handleHandshake(w http.ResponseWriter, r *http.Request) {
	if s.chanKey == nil {
		writeJSON(w, http.StatusServiceUnavailable,
			map[string]any{"ok": false, "error": "channel-disabled"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"alg":         "x25519",
		"serverPub":   s.chanKey.PublicB64(),
		"fingerprint": s.chanKey.Fingerprint(),
	})
}

// handleWS 校验 WS 连接鉴权（M10：请求头 / 子协议，见 auth.md §4.5），未通过 → 401 + 错误码。
//
// 不再接受查询串 ?token=（会进访问日志 / 浏览器历史）；连接与会话绑定，会话吊销即关连接。
func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	token := wsToken(r)
	if token == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "invalid_token"})
		return
	}
	status, _, sessionID := s.store.Authenticate(token)
	switch status {
	case store.AuthExpired:
		writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "token-expired"})
	case store.AuthOK:
		s.hub.Serve(w, r, sessionID, wsSubprotocol(r))
	default:
		writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "invalid_token"})
	}
}

// wsToken 从请求头 / 子协议取访问令牌（§4.5）。
func wsToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		if t := strings.TrimSpace(strings.TrimPrefix(h, "Bearer ")); t != "" {
			return t
		}
	}
	if tok, ok := strings.CutPrefix(wsSubprotocol(r), ws.SubprotocolPrefix); ok {
		return tok
	}
	return ""
}

// wsSubprotocol 返回请求中以 bearer. 前缀承载令牌的子协议。
//
// 浏览器 WebSocket API 无法自定义请求头，子协议是 Web 端唯一可用的令牌通道。
func wsSubprotocol(r *http.Request) string {
	for _, raw := range r.Header.Values("Sec-WebSocket-Protocol") {
		for _, p := range strings.Split(raw, ",") {
			if p = strings.TrimSpace(p); strings.HasPrefix(p, ws.SubprotocolPrefix) {
				return p
			}
		}
	}
	return ""
}

// NewRouter 返回承载受保护 handler 的子路由（供鉴权中间件包裹）。
func NewRouter(s *Server) *http.ServeMux {
	sub := http.NewServeMux()
	sub.HandleFunc("POST /api/v1/sync/push", s.handlePush)
	sub.HandleFunc("GET /api/v1/sync/pull", s.handlePull)
	sub.HandleFunc("HEAD /api/v1/blobs/{hash}", s.handleBlobHead)
	sub.HandleFunc("GET /api/v1/blobs/{hash}", s.handleBlobGet)
	sub.HandleFunc("PUT /api/v1/blobs/{hash}", s.handleBlobPut)
	sub.HandleFunc("GET /api/v1/notes/{id}/revisions", s.handleListRevisions)
	sub.HandleFunc("GET /api/v1/notes/{id}/revisions/{version}", s.handleGetRevision)
	sub.HandleFunc("POST /api/v1/clips", s.handleClip)
	sub.HandleFunc("POST /api/v1/logout", s.handleLogout)
	sub.HandleFunc("POST /api/v1/logout-all", s.handleLogoutAll)
	return sub
}

// wsOriginPatterns 把 SUI_ALLOWED_ORIGINS 的**完整来源**转换成 nhooyr/websocket 需要的
// **主机名**模式（该库按 Origin 的 host 匹配，不比对 scheme）。
//
// "*" 为显式配置的「允许任意来源」，原样透传；空（未配置）→ 只接受同源 Origin。
func wsOriginPatterns(origins []string) []string {
	out := make([]string, 0, len(origins))
	for _, o := range origins {
		if o == "*" {
			return []string{"*"}
		}
		u, err := url.Parse(o)
		if err != nil || u.Host == "" {
			continue
		}
		out = append(out, u.Host)
	}
	return out
}
