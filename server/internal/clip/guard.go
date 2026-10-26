package clip

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"time"
)

// M10-T27：服务端**主动出网**的地址闸门（SSRF 加固）。
//
// 口径见 technology/design/low-level-design/input-validation.md §6 与 clip-engine.md §4.2：
//   - 媒体本地化是服务端唯一的主动出网路径；
//   - 闸门放在 **DialContext**（拨号时校验**解析后的 IP**），因此同时覆盖主机名与 **DNS 重绑定**；
//   - 重定向产生新连接 → **逐跳**自动再过一次闸门，并限制最大跳数；
//   - 命中即失败，由既有降级路径保留原 URL、不阻断整篇剪藏。

// ErrBlockedAddress 表示目标地址落在禁止出网的范围（内网 / 回环 / 链路本地 / CGNAT / 多播 / 未指定）。
var ErrBlockedAddress = errors.New("clip: 目标地址被拒绝（内网 / 回环 / 链路本地 / CGNAT）")

// maxRedirects 是媒体下载允许的最大重定向跳数。
const maxRedirects = 5

// cgnat 为运营商级 NAT 段 100.64.0.0/10（net.IP.IsPrivate 不覆盖它）。
var cgnat = &net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}

// ValidateSourceURL 校验**剪藏来源** URL：只校验 scheme。
//
// 依据 input-validation.md §3：`clips.url` 仅作幂等键与相对 URL 解析基准，服务端从不向它
// 发起请求，故不做地址拦截（否则「剪藏内网页」这类正常用法会被整篇拒绝）。
func ValidateSourceURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("clip: 解析来源地址失败: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("clip: 不支持的协议 %q", u.Scheme)
	}
	return nil
}

// ValidateOutboundURL 校验**服务端将要出网请求**的地址：只做 scheme / 主机名的**形状**校验。
//
// **地址（IP）判定一律留到拨号闸门**（newGuardedClient 的 DialContext），理由有二：
//   - 主机名的解析结果可能在建连前被换掉（DNS 重绑定），只有拨号那一刻拿到的 IP 才可信；
//   - 单一执行点可避免「两道检查各自演化」而出现漏网，也避免解析期多做一次无用 DNS。
func ValidateOutboundURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("clip: 解析地址失败: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("clip: 不支持的协议 %q", u.Scheme)
	}
	if u.Hostname() == "" {
		return nil, errors.New("clip: 地址缺少主机名")
	}
	return u, nil
}

// blockedIP 报告地址是否落在禁止出网的范围。
func blockedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	if v4 := ip.To4(); v4 != nil {
		ip = v4
	}
	return ip.IsLoopback() ||
		ip.IsPrivate() ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() ||
		ip.IsMulticast() ||
		ip.IsInterfaceLocalMulticast() ||
		cgnat.Contains(ip)
}

// newGuardedClient 返回带出网地址闸门的 HTTP 客户端。
func newGuardedClient(timeout time.Duration) *http.Client {
	dialer := &net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		// 刻意**不走**环境代理：否则闸门看到的是代理地址而不是真实目标，
		// 且代理本身可能能访问内网 —— 闸门必须直面目标。
		Proxy:                 nil,
		MaxIdleConns:          10,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
			if err != nil {
				return nil, err
			}
			var lastErr error = ErrBlockedAddress
			for _, cand := range ips {
				if blockedIP(cand.IP) {
					continue
				}
				conn, derr := dialer.DialContext(ctx, network, net.JoinHostPort(cand.IP.String(), port))
				if derr == nil {
					return conn, nil
				}
				lastErr = derr
			}
			return nil, lastErr
		},
	}
	return &http.Client{
		Timeout:   timeout,
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= maxRedirects {
				return fmt.Errorf("clip: 重定向超过 %d 跳", maxRedirects)
			}
			if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
				return fmt.Errorf("clip: 重定向到不支持的协议 %q", req.URL.Scheme)
			}
			// 逐跳的地址判定由 DialContext 闸门完成（每次跳转都是新连接）。
			return nil
		},
	}
}
