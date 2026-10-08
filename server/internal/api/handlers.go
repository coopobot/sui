package api

import (
	"encoding/json"
	"log"
	"net/http"
	"time"

	"sui/note-server/internal/version"
)

// Payload is the shared JSON envelope returned by endpoints.
type Payload struct {
	OK          bool   `json:"ok"`
	Service     string `json:"service"`
	Version     string `json:"version"`
	Time        string `json:"time"`
	Msg         string `json:"msg,omitempty"`
	Initialized bool   `json:"initialized"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	// M10-T24 / BR-52.4：统一安全响应头。
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write json: %v", err)
	}
}

// writeInternalError 把内部错误细节留在服务端日志，只对外回通用错误体。
//
// M10-T24 / BR-52.4：禁止 `error: <err.Error()>` 直出——它会把文件系统路径、
// SQL 细节、模板错误暴露给调用方；细节只进日志。
func writeInternalError(w http.ResponseWriter, r *http.Request, err error) {
	log.Printf("internal error [%s %s]: %v", r.Method, r.URL.Path, err)
	writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": "internal error"})
}

func now() string {
	return time.Now().UTC().Format(time.RFC3339)
}

func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, Payload{
		OK:      true,
		Service: "sui-server",
		Version: version.String,
		Time:    now(),
	})
}

// handlePing 心跳；返回 initialized 供客户端判断是否仍可注册（M4/BR-33.4）。
func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	initialized, err := s.store.HasAnyUser()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": "internal error"})
		return
	}
	writeJSON(w, http.StatusOK, Payload{
		OK:          true,
		Service:     "sui-server",
		Version:     version.String,
		Time:        now(),
		Msg:         "pong",
		Initialized: initialized,
	})
}
