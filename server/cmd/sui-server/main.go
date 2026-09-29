// Sui server — M0 skeleton.
// Assembles the HTTP server and runs it with graceful shutdown.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"sui/note-server/internal/api"
	"sui/note-server/internal/blob"
	"sui/note-server/internal/store"
	"sui/note-server/internal/version"
)

func main() {
	addr := os.Getenv("SUI_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	dataDir := os.Getenv("SUI_DATA")
	if dataDir == "" {
		dataDir = "./data"
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		log.Fatalf("mkdir data: %v", err)
	}

	st, err := store.Open(dataDir + "/sui.db")
	if err != nil {
		log.Fatalf("open store: %v", err)
	}
	defer st.Close()

	blobs, err := blob.NewLocal(dataDir)
	if err != nil {
		log.Fatalf("init blob store: %v", err)
	}

	srv := &http.Server{
		Addr:         addr,
		Handler:      api.New(st, blobs).Router(),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("sui-server v%s listening on %s", version.String, addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	// Graceful shutdown on SIGINT/SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	log.Println("shutting down...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	log.Println("bye")
}
