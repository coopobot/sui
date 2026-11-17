package api

import (
	"context"
	"os"
	"strconv"
	"strings"
	"time"
)

// pullGate 限制**同时在飞**的 pull 响应数量（v0.22.4 / 内存治理）。
//
// 为什么需要：每个 pull 的峰值内存 ≈ 响应体 ×3（逐条编码的瞬时缓冲、受保护通道的整包
// 缓冲、密文 base64），而客户端的「全部重新同步」会对同一实例发起**全量** pull。三台设备
// 同时全量同步，峰值就是单台的 3 倍——在 2 GB 机器上正好是 OOM 的临界点。
//
// 默认只放行 1 个；`SUI_PULL_MAX_CONCURRENT=0`（或负数）关闭闸门。
type pullGate struct {
	slots chan struct{} // nil = 不限制
}

func newPullGate(n int) *pullGate {
	if n <= 0 {
		return &pullGate{}
	}
	return &pullGate{slots: make(chan struct{}, n)}
}

// acquire 取得一个槽位；wait 内拿不到（或 ctx 结束）返回 ok=false。
//
// 先做一次非阻塞尝试：绝大多数 pull 都是「拿得到就走」，不必白起一个 timer。
func (g *pullGate) acquire(ctx context.Context, wait time.Duration) (release func(), ok bool) {
	if g == nil || g.slots == nil {
		return func() {}, true
	}
	select {
	case g.slots <- struct{}{}:
		return func() { <-g.slots }, true
	default:
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case g.slots <- struct{}{}:
		return func() { <-g.slots }, true
	case <-timer.C:
		return nil, false
	case <-ctx.Done():
		return nil, false
	}
}

const (
	defaultPullMaxConcurrent = 1
	defaultPullWaitWindow    = 20 * time.Second
)

// pullMaxConcurrent 返回并发闸门大小（SUI_PULL_MAX_CONCURRENT）。
//
// 与 envInt64 的差别：这里 `0` 是**有意义的值**（关闭闸门），不能被当成「写错回落默认」。
func pullMaxConcurrent() int {
	raw := strings.TrimSpace(os.Getenv("SUI_PULL_MAX_CONCURRENT"))
	if raw == "" {
		return defaultPullMaxConcurrent
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return defaultPullMaxConcurrent
	}
	if v <= 0 {
		return 0
	}
	return v
}

// pullWaitWindow 返回排队等待上限（SUI_PULL_WAIT，默认 20s）。
//
// 超过就回 503 + Retry-After：客户端一次同步有 120s 上限，让它在服务端闸门前排队到超时，
// 不如尽早告诉它「忙」，由既有重试逻辑稍后再来。
func pullWaitWindow() time.Duration {
	return envDuration("SUI_PULL_WAIT", defaultPullWaitWindow)
}
