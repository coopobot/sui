package api

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// M12-T33：登录失败防护门禁（FR-59 / BR-59.1~59.7，auth.md §10，AC-224~AC-231）。
//
// 门禁**不真实等待**：把 guard 的 `sleep` 换成记录器、`now` 换成可控时钟。

func registerGuardUser(t *testing.T, srv *Server, username, password string) {
	t.Helper()
	body, _ := json.Marshal(map[string]string{"username": username, "password": password})
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/register", bytes.NewReader(body)))
	if rec.Code != http.StatusOK {
		t.Fatalf("register: %d %s", rec.Code, rec.Body.String())
	}
}

// loginAttempt 发起一次登录；remote 为空时用 httptest 默认来源，xff 非空时带上转发头。
func loginAttempt(srv *Server, username, password, remote, xff string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"username": username, "password": password})
	req := httptest.NewRequest(http.MethodPost, "/api/v1/login", bytes.NewReader(body))
	if remote != "" {
		req.RemoteAddr = remote
	}
	if xff != "" {
		req.Header.Set("X-Forwarded-For", xff)
	}
	rec := httptest.NewRecorder()
	srv.Router().ServeHTTP(rec, req)
	return rec
}

// guardWithClock 装配「可控时钟 + 记录式 sleep」，返回推进时钟的函数与已记录的延迟。
func guardWithClock(t *testing.T, srv *Server) (advance func(time.Duration), sleeps *[]time.Duration) {
	t.Helper()
	now := time.Now()
	srv.guard.now = func() time.Time { return now }
	recorded := &[]time.Duration{}
	srv.guard.sleep = func(d time.Duration) { *recorded = append(*recorded, d) }
	return func(d time.Duration) { now = now.Add(d) }, recorded
}

// AC-224：阈值内不延迟，达到阈值起按 2 的幂递增（上限封顶）。
func TestM12LoginBackoffAfterThreshold(t *testing.T) {
	t.Setenv("SUI_LOGIN_BACKOFF_AFTER", "3")
	t.Setenv("SUI_LOGIN_BACKOFF_BASE", "2s")
	t.Setenv("SUI_LOGIN_BACKOFF_MAX", "30s")
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "100")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")
	_, sleeps := guardWithClock(t, srv)

	for i := 1; i <= 2; i++ {
		if rec := loginAttempt(srv, "u1", "bad", "10.0.0.1:1234", ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("第 %d 次失败应为 401，实际 %d", i, rec.Code)
		}
	}
	if len(*sleeps) != 0 {
		t.Fatalf("阈值内不应施加延迟，实际 %v", *sleeps)
	}
	if rec := loginAttempt(srv, "u1", "bad", "10.0.0.1:1234", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("第 3 次失败应为 401，实际 %d", rec.Code)
	}
	if len(*sleeps) != 1 || (*sleeps)[0] != 2*time.Second {
		t.Fatalf("达到阈值首次退避应为基数 2s，实际 %v", *sleeps)
	}
	_ = loginAttempt(srv, "u1", "bad", "10.0.0.1:1234", "")
	if len(*sleeps) != 2 || (*sleeps)[1] != 4*time.Second {
		t.Fatalf("后续失败退避应翻倍（4s），实际 %v", *sleeps)
	}
}

// AC-225 / AC-226：超过锁定阈值返回 429 + Retry-After，且锁定期内**正确口令同样被拒**；
// 窗口过期后自动解锁并可正常登录。
func TestM12LoginLockRejectsCorrectPassword(t *testing.T) {
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "3")
	t.Setenv("SUI_LOGIN_LOCK_FOR", "10m")
	t.Setenv("SUI_LOGIN_BACKOFF_AFTER", "100")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")
	advance, _ := guardWithClock(t, srv)

	for i := 1; i <= 2; i++ {
		if rec := loginAttempt(srv, "u1", "bad", "10.0.0.1:1", ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("第 %d 次失败应为 401，实际 %d", i, rec.Code)
		}
	}
	rec := loginAttempt(srv, "u1", "bad", "10.0.0.1:1", "")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("达到锁定阈值应为 429，实际 %d", rec.Code)
	}
	if got := rec.Header().Get("Retry-After"); got != "600" {
		t.Fatalf("Retry-After 应为 600（10 分钟），实际 %q", got)
	}
	if rec := loginAttempt(srv, "u1", "pw", "10.0.0.1:1", ""); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("锁定期内正确口令必须仍被拒（429），实际 %d", rec.Code)
	}
	advance(11 * time.Minute)
	if rec := loginAttempt(srv, "u1", "pw", "10.0.0.1:1", ""); rec.Code != http.StatusOK {
		t.Fatalf("锁定窗口过后应可登录，实际 %d %s", rec.Code, rec.Body.String())
	}
}

// AC-227：登录成功即清零失败计数（否则「1 次失败 + 成功 + 2 次失败」会误触锁定）。
func TestM12LoginSuccessResetsCounter(t *testing.T) {
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "3")
	t.Setenv("SUI_LOGIN_BACKOFF_AFTER", "100")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")

	if rec := loginAttempt(srv, "u1", "bad", "10.0.0.1:1", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("首次失败应为 401，实际 %d", rec.Code)
	}
	if rec := loginAttempt(srv, "u1", "pw", "10.0.0.1:1", ""); rec.Code != http.StatusOK {
		t.Fatalf("正确口令应 200，实际 %d", rec.Code)
	}
	for i := 1; i <= 2; i++ {
		if rec := loginAttempt(srv, "u1", "bad", "10.0.0.1:1", ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("清零后再失败 %d 次不应锁定（阈值 3），实际 %d", i, rec.Code)
		}
	}
}

// AC-228：进程内状态随服务端重启清零 —— 重启即解锁（刻意的逃生口，BR-59.5）。
func TestM12LoginRestartUnlocks(t *testing.T) {
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "2")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")

	_ = loginAttempt(srv, "u1", "bad", "10.0.0.1:1", "")
	if rec := loginAttempt(srv, "u1", "bad", "10.0.0.1:1", ""); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("应进入锁定，实际 %d", rec.Code)
	}
	// 模拟服务端重启：guard 状态（仅驻内存）被整体丢弃。
	srv.guard = newLoginGuard()
	if rec := loginAttempt(srv, "u1", "pw", "10.0.0.1:1", ""); rec.Code != http.StatusOK {
		t.Fatalf("重启后应可登录，实际 %d %s", rec.Code, rec.Body.String())
	}
}

// AC-229：失败 / 锁定写审计日志，字段齐备且**不含口令**。
func TestM12LoginAuditLogHasNoPassword(t *testing.T) {
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "2")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "secret-pw")

	var buf bytes.Buffer
	prev := log.Writer()
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(prev) })

	_ = loginAttempt(srv, "u1", "wrong-secret", "10.0.0.1:1", "")
	_ = loginAttempt(srv, "u1", "wrong-secret", "10.0.0.1:1", "")

	out := buf.String()
	if !strings.Contains(out, "login-fail") || !strings.Contains(out, "login-lock") {
		t.Fatalf("应同时记录 login-fail 与 login-lock，实际：%s", out)
	}
	for _, want := range []string{`user="u1"`, `source="10.0.0.1"`, "fails=1"} {
		if !strings.Contains(out, want) {
			t.Fatalf("审计日志缺少 %q：%s", want, out)
		}
	}
	if strings.Contains(out, "wrong-secret") || strings.Contains(out, "secret-pw") {
		t.Fatalf("审计日志不得包含口令：%s", out)
	}
}

// AC-230：账号不存在与口令错误的响应**完全一致**（不泄露账号存在性）。
func TestM12LoginUnknownUserSameResponse(t *testing.T) {
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")

	existing := loginAttempt(srv, "u1", "bad", "10.0.0.2:1", "")
	unknown := loginAttempt(srv, "nobody", "bad", "10.0.0.3:1", "")
	if existing.Code != unknown.Code || existing.Body.String() != unknown.Body.String() {
		t.Fatalf("响应必须一致：%d %q vs %d %q",
			existing.Code, existing.Body.String(), unknown.Code, unknown.Body.String())
	}
}

// AC-231（默认）：不信任转发头 —— 伪造不同 XFF 不能重置计数。
func TestM12LoginForwardedHeaderNotTrustedByDefault(t *testing.T) {
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "2")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")

	_ = loginAttempt(srv, "u1", "bad", "10.0.0.9:1", "1.1.1.1")
	if rec := loginAttempt(srv, "u1", "bad", "10.0.0.9:1", "2.2.2.2"); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("默认必须忽略 X-Forwarded-For（伪造不得重置计数），实际 %d", rec.Code)
	}
}

// AC-231（显式开启）：按 `X-Forwarded-For` **最右侧**一跳计数，不同来源各自计量。
func TestM12LoginForwardedHeaderTrustedWhenEnabled(t *testing.T) {
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "2")
	t.Setenv("SUI_TRUST_PROXY_HEADERS", "1")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")

	_ = loginAttempt(srv, "u1", "bad", "127.0.0.1:1", "1.1.1.1")
	if rec := loginAttempt(srv, "u1", "bad", "127.0.0.1:1", "2.2.2.2"); rec.Code != http.StatusUnauthorized {
		t.Fatalf("开启信任后不同来源应各自计数，实际 %d", rec.Code)
	}
	if rec := loginAttempt(srv, "u1", "bad", "127.0.0.1:1", "1.1.1.1"); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("同一来源达到阈值应锁定，实际 %d", rec.Code)
	}
}

// `SUI_LOGIN_GUARD=0` 可整体关闭（自托管用户的逃生口）。
func TestM12LoginGuardDisabled(t *testing.T) {
	t.Setenv("SUI_LOGIN_GUARD", "0")
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "2")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")

	for i := 1; i <= 5; i++ {
		if rec := loginAttempt(srv, "u1", "bad", "10.0.0.1:1", ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("关闭防护后第 %d 次仍应为 401，实际 %d", i, rec.Code)
		}
	}
}

// 并发同一键的失败被串行化：状态一致、达到阈值后出现 429（不 panic、不丢计数）。
func TestM12LoginConcurrentFailuresSerialized(t *testing.T) {
	t.Setenv("SUI_LOGIN_LOCK_AFTER", "3")
	t.Setenv("SUI_LOGIN_BACKOFF_AFTER", "100")
	srv := newTestServer(t)
	registerGuardUser(t, srv, "u1", "pw")

	const n = 6
	codes := make([]int, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			codes[i] = loginAttempt(srv, "u1", "bad", "10.0.0.5:1", "").Code
		}(i)
	}
	wg.Wait()

	locked := 0
	for _, c := range codes {
		switch c {
		case http.StatusTooManyRequests:
			locked++
		case http.StatusUnauthorized:
		default:
			t.Fatalf("并发失败出现意外状态码 %d（codes=%v）", c, codes)
		}
	}
	if locked == 0 {
		t.Fatalf("并发失败达到阈值后应至少出现一次 429：%v", codes)
	}
}
