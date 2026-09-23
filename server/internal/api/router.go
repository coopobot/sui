// Package api assembles the HTTP routing for the Sui server.
package api

import (
	"net/http"
)

// NewRouter returns the root mux with all API routes registered.
func NewRouter() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealth)
	mux.HandleFunc("GET /api/v1/ping", handlePing)
	return mux
}