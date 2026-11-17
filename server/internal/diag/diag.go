// Package diag 提供生产环境可用的**只读诊断**入口：周期性内存日志与按需 pprof。
//
// 背景（v0.22.4 / 内存治理）：线上出现「服务端被 OOM Killer 杀掉」时，二进制里既没有
// pprof、也没有内存趋势日志，只能靠 `dmesg` 的一行 total-vm/anon-rss 猜——而 total-vm
// 是 Go 预留的**虚拟地址空间**（常见 1~2 GB），与真实占用（RSS）差一个数量级，极易误判。
//
// 开关：
//   - `SUI_MEM_LOG_INTERVAL`：内存日志周期（默认 `5m`；`0` / `off` 关闭）；
//   - `SUI_PPROF_ADDR`：pprof 监听地址（默认关闭；建议 `127.0.0.1:6060`，**不要暴露公网**）。
package diag

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/pprof"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	"sui/note-server/internal/memlimit"
)

const (
	// PProfAddrEnv 指定 pprof 监听地址；空 = 关闭。
	PProfAddrEnv = "SUI_PPROF_ADDR"
	// MemLogIntervalEnv 指定内存日志周期；`0` / `off` = 关闭。
	MemLogIntervalEnv = "SUI_MEM_LOG_INTERVAL"
	// DefaultMemLogInterval 是内存日志的默认周期。
	DefaultMemLogInterval = 5 * time.Minute
)

// MemLogInterval 解析内存日志周期；非法值回落默认值（与其它 env 解析口径一致）。
func MemLogInterval() time.Duration {
	raw := strings.ToLower(strings.TrimSpace(os.Getenv(MemLogIntervalEnv)))
	if raw == "" {
		return DefaultMemLogInterval
	}
	switch raw {
	case "0", "off", "none", "false", "disabled":
		return 0
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d <= 0 {
		return DefaultMemLogInterval
	}
	return d
}

// LogMemory 输出一行内存快照。
//
// `rss` 取自 `/proc/self/status` 的 VmRSS（Linux）；其它平台为空。`gomemlimit` 是
// 当前生效的软上限（未设置时显示 unlimited）。
func LogMemory() {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	limit := debug.SetMemoryLimit(-1) // 传负值只读取，不修改
	log.Printf(
		"mem: rss=%s heapAlloc=%s heapSys=%s heapIdle=%s heapInuse=%s stack=%s goroutines=%d gomemlimit=%s",
		rssString(),
		memlimit.HumanBytes(int64(ms.HeapAlloc)),
		memlimit.HumanBytes(int64(ms.HeapSys)),
		memlimit.HumanBytes(int64(ms.HeapIdle)),
		memlimit.HumanBytes(int64(ms.HeapInuse)),
		memlimit.HumanBytes(int64(ms.StackInuse)),
		runtime.NumGoroutine(),
		memlimit.HumanBytes(limit),
	)
}

// RunMemLog 按 interval 周期输出内存快照，直到 ctx 结束；启动时先输出一行。
func RunMemLog(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		return
	}
	LogMemory()
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			LogMemory()
		}
	}
}

// StartPProf 在 addr 上启动只读 pprof 监听，返回 server、实际监听地址与错误。
//
// 独立监听（而不是挂到主 mux）是刻意的：pprof 不经过鉴权中间件，绑在业务端口上
// 等于把堆快照暴露给任何能访问业务端口的人。
func StartPProf(addr string) (*http.Server, string, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, "", fmt.Errorf("pprof listen %s: %w", addr, err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	srv := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := srv.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("pprof server: %v", err)
		}
	}()
	actual := ln.Addr().String()
	if !isLoopback(actual) {
		log.Printf("WARNING: pprof listening on %s（非回环地址；请勿暴露到公网）", actual)
	}
	log.Printf("pprof on http://%s/debug/pprof/ (heap / goroutine / profile / trace)", actual)
	return srv, actual, nil
}

func isLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "" {
		return false
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// rssString 读取当前进程 RSS（Linux；其它平台返回 "?"）。
func rssString() string {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return "?"
	}
	for _, line := range strings.Split(string(data), "\n") {
		if !strings.HasPrefix(line, "VmRSS:") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return "?"
		}
		kb, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil {
			return "?"
		}
		return memlimit.HumanBytes(kb * 1024)
	}
	return "?"
}
