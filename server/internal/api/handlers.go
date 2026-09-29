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
	OK      bool   `json:"ok"`
	Service string `json:"service"`
	Version string `json:"version"`
	Time    string `json:"time"`
	Msg     string `json:"msg,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write json: %v", err)
	}
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

func handlePing(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, Payload{
		OK:      true,
		Service: "sui-server",
		Version: version.String,
		Time:    now(),
		Msg:     "pong",
	})
}
