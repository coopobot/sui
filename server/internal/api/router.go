// Package api assembles the HTTP routing for the Sui server.
package api

import (
	"net/http"

	"sui/note-server/internal/auth"
	"sui/note-server/internal/blob"
	"sui/note-server/internal/store"
	"sui/note-server/internal/sync"
)

// Server 持有所需依赖，并将 API 路由注册到 mux。
type Server struct {
	store *store.Store
	blobs blob.Store
	sync  *sync.Protocol
}

// New 创建带依赖的 API Server。
func New(st *store.Store, blobs blob.Store) *Server {
	return &Server{store: st, blobs: blobs, sync: sync.New(st)}
}

// Router 返回根 mux：公开路由 + 挂在 /api/v1/per 下的受保护路由。
func (s *Server) Router() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealth)
	mux.HandleFunc("GET /api/v1/ping", handlePing)
	mux.HandleFunc("POST /api/v1/register", s.handleRegister)

	// 受保护路由挂载在同一 mux 下，注册在任意路径上，交由 auth 中间件包裹。
	// 注意：Go 1.22 的 ServeMux 支持 METHOD + 方法。这里需要按方法+路径注册，
	// 因此将受保护 handler 显式注册到具体路径，而不是包一层。
	root := NewRouter(s)
	authWrap := auth.Middleware(s.store, root)
	mux.Handle("/api/v1/sync/push", authWrap)
	mux.Handle("/api/v1/sync/pull", authWrap)
	mux.Handle("/api/v1/blobs/", authWrap)
	mux.Handle("/api/v1/notes/", authWrap)
	return mux
}

// NewRouter 返回承载受保护 handler 的子路由（供鉴权中间件包裹）。
func NewRouter(s *Server) *http.ServeMux {
	sub := http.NewServeMux()
	sub.HandleFunc("POST /api/v1/sync/push", s.handlePush)
	sub.HandleFunc("GET /api/v1/sync/pull", s.handlePull)
	sub.HandleFunc("HEAD /api/v1/blobs/{hash}", s.handleBlobHead)
	sub.HandleFunc("PUT /api/v1/blobs/{hash}", s.handleBlobPut)
	sub.HandleFunc("GET /api/v1/notes/{id}/revisions", s.handleListRevisions)
	sub.HandleFunc("GET /api/v1/notes/{id}/revisions/{version}", s.handleGetRevision)
	return sub
}