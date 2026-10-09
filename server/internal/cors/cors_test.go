package cors

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// v0.11.2：CORS 与受保护通道（M10-T27）的跨源适配门禁。
//
// 关注点不是「有没有 CORS」，而是**受保护通道的自定义头有没有被放行 / 暴露**：
// 少列请求头 → Web 端预检被拒；少列响应头 → Web 端读不到 `X-Sui-Enc` 而把密文当明文。

func okHandler(called *bool) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*called = true
		w.WriteHeader(http.StatusOK)
	})
}

func TestAllowedOriginGetsChannelHeaders(t *testing.T) {
	var called bool
	h := Middleware([]string{"http://localhost:8000"}, okHandler(&called))

	req := httptest.NewRequest(http.MethodPost, "/api/v1/login", nil)
	req.Header.Set("Origin", "http://localhost:8000")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "http://localhost:8000" {
		t.Fatalf("Allow-Origin = %q，期望精确回显白名单来源", got)
	}
	if got := rec.Header().Get("Vary"); got != "Origin" {
		t.Fatalf("Vary = %q，期望 Origin（避免缓存串源）", got)
	}
	allow := rec.Header().Get("Access-Control-Allow-Headers")
	for _, h := range []string{"X-Sui-Enc", "X-Sui-Eph", "X-Sui-Req-Id", "Authorization", "Content-Type"} {
		if !strings.Contains(allow, h) {
			t.Fatalf("Allow-Headers 缺少 %s：%q", h, allow)
		}
	}
	expose := rec.Header().Get("Access-Control-Expose-Headers")
	if !strings.Contains(expose, "X-Sui-Enc") {
		t.Fatalf("Expose-Headers 必须含 X-Sui-Enc（否则 Web 端读不到密文标记）：%q", expose)
	}
	if !called {
		t.Fatal("非 OPTIONS 请求必须继续交给下游处理")
	}
}

func TestUnlistedOriginGetsNoCORSHeaders(t *testing.T) {
	var called bool
	h := Middleware([]string{"http://localhost:8000"}, okHandler(&called))

	req := httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil)
	req.Header.Set("Origin", "http://evil.example")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("未列入白名单的来源不得回 Allow-Origin，实际 %q", got)
	}
	// 服务端照常服务（CORS 由浏览器执行），但**不能**给跨源放行信号。
	if !called {
		t.Fatal("CORS 中间件不应在服务端直接拦截请求")
	}
}

func TestEmptyWhitelistDeniesEverything(t *testing.T) {
	h := Middleware(nil, okHandler(new(bool)))
	req := httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil)
	req.Header.Set("Origin", "http://localhost:8000")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("空白名单（SUI_ALLOWED_ORIGINS 未配置）必须默认拒绝，实际回了 %q", got)
	}
}

func TestNoOriginUnaffected(t *testing.T) {
	var called bool
	h := Middleware([]string{"http://localhost:8000"}, okHandler(&called))
	req := httptest.NewRequest(http.MethodGet, "/api/v1/ping", nil) // 无 Origin：桌面 / 移动 / curl
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "" {
		t.Fatalf("无 Origin 的调用不应产生 CORS 头，实际 %q", got)
	}
	if !called {
		t.Fatal("无 Origin 的调用必须正常处理")
	}
}

func TestPreflightShortCircuits(t *testing.T) {
	var called bool
	h := Middleware([]string{"http://localhost:8000"}, okHandler(&called))
	req := httptest.NewRequest(http.MethodOptions, "/api/v1/login", nil)
	req.Header.Set("Origin", "http://localhost:8000")
	req.Header.Set("Access-Control-Request-Method", "POST")
	req.Header.Set("Access-Control-Request-Headers", "x-sui-enc,x-sui-eph,x-sui-req-id")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("预检应回 204，实际 %d", rec.Code)
	}
	if called {
		t.Fatal("预检不得进入下游 handler（否则会触发鉴权 / 解密等业务逻辑）")
	}
}
