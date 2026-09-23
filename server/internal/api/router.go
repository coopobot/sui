// Package api assembles the HTTP routing for the Sui server.
package api

import (
	"net/http"

	"sui/note-server/internal/auth"
	"sui/note-server/internal/blob"
	"sui/note-server/internal/cors"
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

// Router 返回根 mux：CORS 包裹 + 公开路由 + 受保护路由。
func (s *Server) Router() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealth)
	mux.HandleFunc("GET /api/v1/ping", handlePing)
	mux.HandleFunc("POST /api/v1/register", s.handleRegister)
	mux.HandleFunc("POST /api/v1/login", s.handleLogin)

	// WebSocket 端点（公开连接，实际业务消息由客户端自行鉴权）
	mux.HandleFunc("GET /api/v1/ws", s.hub.Handle)

	// 受保护路由挂载在同一 mux 下，交由 auth 中间件包裹。
	root := NewRouter(s)
	authWrap := auth.Middleware(s.store, root)
	mux.Handle("/api/v1/sync/push", authWrap)
	mux.Handle("/api/v1/sync/pull", authWrap)
	mux.Handle("/api/v1/blobs/", authWrap)
	mux.Handle("/api/v1/notes/", authWrap)
	mux.Handle("/api/v1/clips", authWrap)

	// CORS 中间件包裹最外层
	return cors.Middleware(nil, mux) // 空 origin 列表 = 开发模式全允许
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
	return sub
}
