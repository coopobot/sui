// Sui server — 单二进制自托管入口。
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
	"sui/note-server/internal/securechan"
	"sui/note-server/internal/store"
	"sui/note-server/internal/version"
)

func main() {
	addr := os.Getenv("SUI_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	dataDir := os.Getenv("SUI_DATA")
	if dataDir == "" {
		dataDir = "./data"
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
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

	apiSrv := api.New(st, blobs)
	// M10-T27 / FR-50：受保护通道的长期密钥（首次启动生成并持久化，0600；信任根，TOFU + 指纹）。
	chanKey, err := securechan.LoadOrCreateKey(dataDir + "/securechan.key")
	if err != nil {
		log.Fatalf("init secure channel key: %v", err)
	}
	apiSrv.SetChannelKey(chanKey)
	log.Printf("secure channel ready (fingerprint %s)", chanKey.Fingerprint())

	srv := &http.Server{
		Addr:    addr,
		Handler: apiSrv.Router(),
		// M10-T25 / BR-52.5（input-validation.md §8）：补 ReadHeaderTimeout 防慢速
		// 请求头攻击、补 IdleTimeout 回收keep-alive 空闲连接；既有 Read/Write 保持不变。
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
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
