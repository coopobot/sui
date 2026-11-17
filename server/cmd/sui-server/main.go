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
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"sui/note-server/internal/api"
	"sui/note-server/internal/blob"
	"sui/note-server/internal/diag"
	"sui/note-server/internal/memlimit"
	"sui/note-server/internal/securechan"
	"sui/note-server/internal/store"
	"sui/note-server/internal/version"
)

func main() {
	// M23 / 内存治理（ADR-048）：给 Go 运行时设**软内存上限**（等价 GOMEMLIMIT）。
	// 默认按容器 cgroup 限额或物理内存推导；显式 SUI_MEMORY_LIMIT 优先（`0` 关闭）。
	// 作用：让 GC 在接近上限时提前加力，压住「堆按 GOGC 翻倍」的峰值，降低被 OOM Killer 选中的概率。
	if limit, src := memlimit.Resolve(os.Getenv(memlimit.Env), nil); limit > 0 {
		debug.SetMemoryLimit(limit)
		log.Printf("memory limit: %s (source: %s)", memlimit.HumanBytes(limit), src)
	} else {
		log.Printf("memory limit: disabled (source: %s)", src)
	}

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

	var blobs blob.Store
	if os.Getenv("SUI_BLOB_STORE") == "s3" {
		// M22 / FR-121 / ADR-045：S3 兼容对象存储。
		s3Store, err := blob.NewS3(context.Background(), blob.S3ConfigFromEnv())
		if err != nil {
			log.Fatalf("init s3 blob store: %v", err)
		}
		blobs = s3Store
		log.Printf("blob store: s3 bucket=%s endpoint=%s", os.Getenv("SUI_S3_BUCKET"), os.Getenv("SUI_S3_ENDPOINT"))
	} else {
		local, err := blob.NewLocal(dataDir)
		if err != nil {
			log.Fatalf("init blob store: %v", err)
		}
		blobs = local
	}
	// M20 / FR-119：启动时清理超过 24h 的未完成分片会话（不阻塞启动）。
	if chunks, ok := blobs.(blob.ChunkedStore); ok {
		_ = chunks.CleanupUploads(time.Now())
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

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// v0.22.4 / 内存治理：只读诊断面 —— pprof（默认关闭，建议只绑回环）+ 周期内存日志。
	if pprofAddr := strings.TrimSpace(os.Getenv(diag.PProfAddrEnv)); pprofAddr != "" {
		if ps, _, perr := diag.StartPProf(pprofAddr); perr != nil {
			log.Printf("pprof disabled: %v", perr)
		} else {
			defer func() { _ = ps.Close() }()
		}
	}
	if iv := diag.MemLogInterval(); iv > 0 {
		log.Printf("memory log every %s", iv)
		go diag.RunMemLog(ctx, iv)
	}

	go func() {
		log.Printf("sui-server v%s listening on %s", version.String, addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("listen: %v", err)
		}
	}()

	// Graceful shutdown on SIGINT/SIGTERM.
	<-ctx.Done()
	log.Println("shutting down...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	log.Println("bye")
}
