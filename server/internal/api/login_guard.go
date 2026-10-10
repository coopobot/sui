package api

import (
	"log"
	"math"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 登录失败防护（M12 修订 / FR-59，见 auth.md §10、ADR-023）。
//
// 定位：在不引入依赖、不改失败响应语义（不泄露账号存在性）的前提下，为 `POST /api/v1/login`
// 加上**次数 + 延迟 + 锁定**三重限制与审计。
//
// 设计要点：
//   - **进程内**状态（不落库）：服务端重启即全部清零 —— 这是**刻意的逃生口**（单用户实例下
//     避免把唯一用户永久锁在门外，BR-59.5）；
//   - 键 = `lower(username) + "\n" + 来源`（来源默认取**直连对端**，仅显式开启时才信任
//     `X-Forwarded-For` 的**最右侧**一跳，BR-59.1 / BR-59.6）；
//   - **同键串行化**：同一键同时只允许一个尝试在延迟中，避免攻击者用并发请求把大量 goroutine
//     睡在延迟上（延迟放大 DoS）；
//   - 阈值 / 退避 / 锁定窗口全部可用环境变量覆盖，时钟与 sleep 可注入（门禁不因真实等待变慢）。
//
// 明确不做（BR-59.9）：不做计数落库、不做永久封禁、不做验证码、不做密码强度强制。

const (
	defaultLoginBackoffAfter = 5                // 连续失败达到该次数后开始退避
	defaultLoginBackoffBase  = time.Second      // 退避基数
	defaultLoginBackoffMax   = 30 * time.Second // 退避上限
	defaultLoginLockAfter    = 10               // 连续失败达到该次数后锁定
	defaultLoginLockFor      = 15 * time.Minute // 锁定时长
	defaultLoginGuardMaxKeys = 4096             // 键表上限（防内存增长）
)

// loginEntry 是**单个键**（用户名 + 来源）的失败状态。
//
// mu 同时承担「同键串行化」：`begin` 持锁直到请求结束（`release`），
// 故同一键的并发登录尝试被排队，退避延迟不会被并发放大。
type loginEntry struct {
	mu          sync.Mutex
	fails       int
	lockedUntil time.Time
	lastSeen    time.Time
}

// loginGuard 持有全部键的状态（进程内）。
type loginGuard struct {
	mu      sync.Mutex
	entries map[string]*loginEntry
	// now / sleep 可注入：门禁用假时钟与记录式 sleep，避免真实等待。
	now     func() time.Time
	sleep   func(time.Duration)
	maxKeys int
}

func newLoginGuard() *loginGuard {
	return &loginGuard{
		entries: make(map[string]*loginEntry),
		now:     time.Now,
		sleep:   time.Sleep,
		maxKeys: int(envInt64("SUI_LOGIN_GUARD_MAX_KEYS", defaultLoginGuardMaxKeys)),
	}
}

// ---- 配置（环境变量，非法值一律回落默认值）----

// loginGuardEnabled 报告防护是否启用（`SUI_LOGIN_GUARD=0` 关闭）。
func loginGuardEnabled() bool { return envBool("SUI_LOGIN_GUARD", true) }

func loginBackoffAfter() int {
	return int(envInt64("SUI_LOGIN_BACKOFF_AFTER", defaultLoginBackoffAfter))
}
func loginBackoffBase() time.Duration {
	return envDuration("SUI_LOGIN_BACKOFF_BASE", defaultLoginBackoffBase)
}
func loginBackoffMax() time.Duration {
	return envDuration("SUI_LOGIN_BACKOFF_MAX", defaultLoginBackoffMax)
}
func loginLockAfter() int         { return int(envInt64("SUI_LOGIN_LOCK_AFTER", defaultLoginLockAfter)) }
func loginLockFor() time.Duration { return envDuration("SUI_LOGIN_LOCK_FOR", defaultLoginLockFor) }
func trustProxyHeaders() bool     { return envBool("SUI_TRUST_PROXY_HEADERS", false) }

// envBool 解析布尔环境变量；未设置 / 空值取 def，`0|false|off|no` 为假。
func envBool(key string, def bool) bool {
	raw := strings.ToLower(strings.TrimSpace(os.Getenv(key)))
	if raw == "" {
		return def
	}
	switch raw {
	case "0", "false", "off", "no":
		return false
	default:
		return true
	}
}

// ---- 键与来源 ----

// loginKey 返回计数键：用户名（小写）+ 来源地址（BR-59.1）。
func loginKey(username string, r *http.Request) string {
	return strings.ToLower(strings.TrimSpace(username)) + "\n" + loginSource(r)
}

// loginSource 返回本次尝试的来源地址（BR-59.6）。
//
// 默认只信任**直连对端**（`RemoteAddr`）——转发头可被客户端伪造，故只有显式开启
// `SUI_TRUST_PROXY_HEADERS` 时才取 `X-Forwarded-For` 的**最右侧**一跳（单层可信反代语义）。
func loginSource(r *http.Request) string {
	if trustProxyHeaders() {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			if ip := strings.TrimSpace(parts[len(parts)-1]); ip != "" {
				return ip
			}
		}
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

// ---- 状态访问 ----

// entry 返回该键的状态对象，必要时按 LRU 淘汰（键表有界，防内存增长）。
func (g *loginGuard) entry(key string) *loginEntry {
	g.mu.Lock()
	defer g.mu.Unlock()
	if e, ok := g.entries[key]; ok {
		return e
	}
	if len(g.entries) >= g.maxKeys {
		g.evictLocked()
	}
	e := &loginEntry{lastSeen: g.now()}
	g.entries[key] = e
	return e
}

// evictLocked 在键表满时淘汰最久未使用的**未被持有**的键（g.mu 已持有）。
func (g *loginGuard) evictLocked() {
	var oldestKey string
	var oldest time.Time
	for k, e := range g.entries {
		if !e.mu.TryLock() {
			continue // 正在处理中，跳过
		}
		e.mu.Unlock()
		if oldestKey == "" || e.lastSeen.Before(oldest) {
			oldestKey, oldest = k, e.lastSeen
		}
	}
	if oldestKey != "" {
		delete(g.entries, oldestKey)
	}
}

// ---- 判定与记账 ----

// begin 在**校验口令之前**调用：取得该键的独占权（同键串行化）并判定是否处于锁定窗口。
//
// 返回的 release **必须**被调用（即使 locked 为真）；locked 为真时 retryAfter 为建议的
// `Retry-After` 秒数（>= 1）。
func (g *loginGuard) begin(username string, r *http.Request) (release func(), locked bool, retryAfter int) {
	if !loginGuardEnabled() {
		return func() {}, false, 0
	}
	e := g.entry(loginKey(username, r))
	e.mu.Lock()
	now := g.now()
	e.lastSeen = now
	if !e.lockedUntil.IsZero() && now.Before(e.lockedUntil) {
		return e.mu.Unlock, true, retryAfterSeconds(e.lockedUntil.Sub(now))
	}
	if !e.lockedUntil.IsZero() {
		// 锁定窗口已过：解锁并审计（BR-59.7）。
		log.Printf("login-unlock user=%q source=%q reason=expired", username, loginSource(r))
		e.lockedUntil = time.Time{}
		e.fails = 0
	}
	return e.mu.Unlock, false, 0
}

// failure 在口令校验失败后调用（**必须**在 begin 的 release 之前，即同键锁仍被持有）。
//
// 返回值：本次施加的退避延迟、是否已锁定、锁定时建议的 Retry-After 秒数。
func (g *loginGuard) failure(username string, r *http.Request) (delay time.Duration, locked bool, retryAfter int) {
	if !loginGuardEnabled() {
		return 0, false, 0
	}
	e := g.entry(loginKey(username, r))
	e.fails++
	source := loginSource(r)
	if e.fails >= loginLockAfter() {
		lockFor := loginLockFor()
		e.lockedUntil = g.now().Add(lockFor)
		log.Printf("login-lock user=%q source=%q fails=%d lockFor=%s", username, source, e.fails, lockFor)
		return 0, true, retryAfterSeconds(lockFor)
	}
	log.Printf("login-fail user=%q source=%q fails=%d", username, source, e.fails)
	if e.fails >= loginBackoffAfter() {
		delay = backoffDelay(e.fails, loginBackoffAfter(), loginBackoffBase(), loginBackoffMax())
		g.sleep(delay)
		return delay, false, 0
	}
	return 0, false, 0
}

// success 在登录成功后调用：清零该键的失败计数与锁定状态（BR-59.4）。
func (g *loginGuard) success(username string, r *http.Request) {
	if !loginGuardEnabled() {
		return
	}
	e := g.entry(loginKey(username, r))
	had := e.fails
	e.fails = 0
	e.lockedUntil = time.Time{}
	if had > 0 {
		log.Printf("login-success user=%q source=%q afterFails=%d", username, loginSource(r), had)
	}
}

// backoffDelay 计算第 n 次连续失败应施加的延迟：base × 2^(n-after)，上限 max。
//
// 边界：`n == after`（恰好达到阈值）即施加**基数**延迟（BR-59.2 的「1s → 2s → 4s…」），
// 故只有 `n < after` 才不延迟。
func backoffDelay(n, after int, base, max time.Duration) time.Duration {
	if n < after {
		return 0
	}
	d := base
	for i := 0; i < n-after; i++ {
		if d >= max {
			return max
		}
		d *= 2
	}
	if d > max {
		return max
	}
	return d
}

// retryAfterSeconds 把剩余时长换算为 `Retry-After` 秒数（向上取整，至少 1）。
func retryAfterSeconds(d time.Duration) int {
	if d <= 0 {
		return 1
	}
	s := int(math.Ceil(d.Seconds()))
	if s < 1 {
		return 1
	}
	return s
}

// writeLoginLocked 返回锁定期响应：`429` + `Retry-After`（BR-59.3）。
//
// 文案不透露阈值、剩余次数与账号是否存在。
func writeLoginLocked(w http.ResponseWriter, retryAfter int) {
	if retryAfter < 1 {
		retryAfter = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
	writeJSON(w, http.StatusTooManyRequests, map[string]any{"ok": false, "error": "too-many-attempts"})
}
