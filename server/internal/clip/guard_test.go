package clip

import (
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// M10-T27：出网地址闸门（SSRF 加固）门禁。

func TestBlockedIP(t *testing.T) {
	blocked := []string{
		"127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1",
		"169.254.169.254", // 云元数据
		"100.64.0.1",      // CGNAT
		"0.0.0.0", "224.0.0.1",
		"::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1",
	}
	for _, s := range blocked {
		if !blockedIP(net.ParseIP(s)) {
			t.Errorf("%s 应被拒绝出网", s)
		}
	}
	allowed := []string{"8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111"}
	for _, s := range allowed {
		if blockedIP(net.ParseIP(s)) {
			t.Errorf("%s 应允许出网", s)
		}
	}
	if !blockedIP(nil) {
		t.Error("nil 地址应视为被拒")
	}
}

func TestValidateOutboundURL(t *testing.T) {
	// 形状校验：scheme 与主机名。**地址判定不在此处**（只认拨号闸门，见 TestGuardedClient*）。
	bad := []string{"", "ftp://example.com/a.png", "file:///etc/passwd", "https:///no-host", "http:///a.png"}
	for _, s := range bad {
		if _, err := ValidateOutboundURL(s); err == nil {
			t.Errorf("%q 应被拒绝", s)
		}
	}
	// 含内网 IP 字面量的地址在**形状层放行**，由拨号闸门拒绝（刻意的单一执行点）。
	shapeOK := []string{"http://example.com/a.png", "https://93.184.216.34/a.png", "http://127.0.0.1/a.png"}
	for _, s := range shapeOK {
		if _, err := ValidateOutboundURL(s); err != nil {
			t.Errorf("%q 形状应合法，实际 %v", s, err)
		}
	}
}

// 拨号闸门：即便调用方绕过 ValidateOutboundURL，指向回环的请求也必须在**连接层**被拒。
func TestGuardedClientRefusesLoopbackAtDial(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("secret"))
	}))
	defer srv.Close()

	client := newGuardedClient(3 * time.Second)
	resp, err := client.Get(srv.URL)
	if err == nil {
		resp.Body.Close()
		t.Fatalf("指向本机 %s 的请求应被闸门拒绝，却成功了", srv.URL)
	}
	if !errors.Is(err, ErrBlockedAddress) {
		t.Errorf("错误应可识别为地址被拒，实际 %v", err)
	}
}

// 重定向：跳数上限与非 http(s) 目标由 CheckRedirect 挡住（地址判定在拨号处逐跳生效）。
func TestGuardedClientRedirectPolicy(t *testing.T) {
	c := newGuardedClient(time.Second)

	via := make([]*http.Request, maxRedirects)
	req, _ := http.NewRequest(http.MethodGet, "http://example.com/a.png", nil)
	if err := c.CheckRedirect(req, via); err == nil {
		t.Errorf("超过 %d 跳应被拒", maxRedirects)
	}

	bad, _ := http.NewRequest(http.MethodGet, "ftp://example.com/a.png", nil)
	if err := c.CheckRedirect(bad, nil); err == nil {
		t.Error("跳转到非 http(s) 应被拒")
	}

	ok, _ := http.NewRequest(http.MethodGet, "https://example.com/a.png", nil)
	if err := c.CheckRedirect(ok, nil); err != nil {
		t.Errorf("常规跳转应放行，实际 %v", err)
	}
}

// 剪藏来源只校验 scheme（服务端不向它出网，故不做地址拦截）。
func TestValidateSourceURL(t *testing.T) {
	for _, s := range []string{"https://example.com/a", "http://127.0.0.1:8080/intranet/page"} {
		if err := ValidateSourceURL(s); err != nil {
			t.Errorf("%q 应放行（来源不做地址拦截），实际 %v", s, err)
		}
	}
	for _, s := range []string{"ftp://example.com/a", "file:///etc/passwd", "javascript:alert(1)"} {
		if err := ValidateSourceURL(s); err == nil {
			t.Errorf("%q 的 scheme 应被拒", s)
		}
	}
}
