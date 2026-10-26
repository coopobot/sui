package api

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

// M10-T27（SSRF 半边）在 API 层的表现：出网地址命中拦截走**降级**（不阻断整篇），
// 而剪藏来源只校验 scheme（内网来源仍可正常剪藏）。

func TestM10ClipMediaFromPrivateAddressDegrades(t *testing.T) {
	srv, _, dir := newM10Server(t)
	token := register(t, srv)

	html := `<html><body><article><h1>标题</h1><p>正文</p>` +
		`<img src="http://127.0.0.1:9/pwn.png" alt="x"></article></body></html>`
	body, _ := json.Marshal(map[string]any{"url": "https://page.example/a", "title": "t", "html": html})
	rec := authReq(srv, token, http.MethodPost, "/api/v1/clips", body)
	if rec.Code != http.StatusOK {
		t.Fatalf("单图被拦截应降级而非失败整篇，实际 %d %s", rec.Code, rec.Body.String())
	}
	var out struct {
		Unlocalized int `json:"unlocalizedImages"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Unlocalized < 1 {
		t.Errorf("内网图片地址应被拦截并计入「未本地化」，实际 %d", out.Unlocalized)
	}
	entries, err := os.ReadDir(filepath.Join(dir, "blobs"))
	if err == nil && len(entries) != 0 {
		t.Errorf("被拦截的图片不应落盘，blobs=%v", entries)
	}
}

func TestM10ClipSourceURLSchemeOnly(t *testing.T) {
	srv, _, _ := newM10Server(t)
	token := register(t, srv)

	// 非 http(s) 来源 → 400
	body, _ := json.Marshal(map[string]any{"url": "ftp://example.com/a", "html": "<p>x</p>"})
	if rec := authReq(srv, token, http.MethodPost, "/api/v1/clips", body); rec.Code != http.StatusBadRequest {
		t.Errorf("非 http(s) 来源应 400，实际 %d %s", rec.Code, rec.Body.String())
	}

	// 内网来源 → 放行（服务端不向来源出网，地址拦截只针对媒体下载）
	body, _ = json.Marshal(map[string]any{"url": "http://10.0.0.9/intranet/page", "html": "<p>x</p>"})
	if rec := authReq(srv, token, http.MethodPost, "/api/v1/clips", body); rec.Code != http.StatusOK {
		t.Errorf("内网来源应放行（仅校验 scheme），实际 %d %s", rec.Code, rec.Body.String())
	}
}
