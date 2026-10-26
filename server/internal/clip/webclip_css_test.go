package clip

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/net/html"
)

// M16 / FR-83 补丁：跨域 / 同域外部样式表由服务端拉取并内联。
//
// 浏览器扩展只能读到同源 / 内联 CSS；跨域样式表在 page 上下文读 cssRules 会抛
// SecurityError，fetch 也可能被 CORS 拒绝。服务端有出网能力，因此由这里补齐。
func TestBuildWebClipHTMLInlinesExternalCSS(t *testing.T) {
	cssSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/style.css" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/css")
		_, _ = w.Write([]byte(`.hero{color:red;background:url(/bg.png)}`))
	}))
	defer cssSrv.Close()

	raw := `<html><head><link rel="stylesheet" href="/style.css"></head>` +
		`<body><div class="hero">居中</div></body></html>`
	doc, err := html.Parse(strings.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	out := BuildWebClipHTML(doc, cssSrv.URL+"/page", cssSrv.Client())
	if !strings.Contains(out, "color:red") {
		t.Fatalf("外部 CSS 应被内联：%q", out)
	}
	if strings.Contains(out, "<link") {
		t.Fatalf("内联后不应保留 stylesheet link：%q", out)
	}
	if !strings.Contains(out, `url("`+cssSrv.URL+`/bg.png")`) {
		t.Fatalf("CSS 相对 url 应改写为绝对地址：%q", out)
	}
}

func TestBuildWebClipHTMLCSSFailureDoesNotBlock(t *testing.T) {
	cssSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer cssSrv.Close()

	raw := `<html><head><link rel="stylesheet" href="/missing.css"></head>` +
		`<body><p>正文仍在</p></body></html>`
	doc, err := html.Parse(strings.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	out := BuildWebClipHTML(doc, cssSrv.URL+"/page", cssSrv.Client())
	if !strings.Contains(out, "正文仍在") {
		t.Fatalf("CSS 失败不得丢正文：%q", out)
	}
}
