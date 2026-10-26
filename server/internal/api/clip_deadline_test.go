package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// slowImageTransport 是「慢图床」桩：每张图固定延迟，不触网。
type slowImageTransport struct {
	delay time.Duration
	body  []byte
}

func (s slowImageTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	time.Sleep(s.delay)
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"image/png"}},
		Body:       io.NopCloser(bytes.NewReader(s.body)),
		Request:    r,
	}, nil
}

// v0.13.2 / AC-268：剪藏的处理时长可以超过全局 `WriteTimeout`
// （媒体本地化预算是 30s，全局 `WriteTimeout` 是 10s）。
//
// 本用例刻意用**真实 `http.Server`**（`httptest.NewUnstartedServer` + 小 `WriteTimeout`）
// 配「慢图床」桩：`httptest.NewRecorder` 这类不走网络、不设期限的用法**抓不到**该缺陷。
// 修复前 `handleClip` 只延长了**读**期限，于是响应被写期限切断 ——
// **笔记已落库、客户端却拿到空响应**（浏览器侧表现为 `Failed to fetch`，用户视角是「剪藏失败」）。
func TestClipSurvivesGlobalWriteTimeout(t *testing.T) {
	srv := newTestServer(t)
	srv.SetMediaClient(&http.Client{
		Transport: slowImageTransport{delay: 600 * time.Millisecond, body: []byte("fake-image-bytes")},
	})

	ts := httptest.NewUnstartedServer(srv.Router())
	ts.Config.WriteTimeout = 1 * time.Second
	ts.Config.ReadTimeout = 30 * time.Second
	ts.Start()
	defer ts.Close()

	token := register(t, srv) // 令牌落在同一个 store 里，TCP 服务端同样认

	html := `<html><head><title>慢图页</title></head><body><article>` +
		`<p><img src="https://images.example.com/a.png"></p>` +
		`<p><img src="https://images.example.com/b.png"></p>` +
		`</article></body></html>`
	payload, _ := json.Marshal(map[string]string{
		"url": "https://example.com/slow", "title": "慢图页", "html": html, "mode": "snapshot",
	})
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/clips", bytes.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	start := time.Now()
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		t.Fatalf("剪藏请求失败（全局写期限把响应切断了？）：%v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("期望 200，实际 %d", resp.StatusCode)
	}
	var out clipResp
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("响应体不是完整 JSON（写期限切断）：%v", err)
	}
	if !out.OK || out.NoteID == "" {
		t.Fatalf("剪藏响应不完整：%+v", out)
	}
	if elapsed := time.Since(start); elapsed < 1*time.Second {
		t.Fatalf("用例前提不成立：处理仅耗时 %v，未超过 WriteTimeout(1s)——请检查慢图桩", elapsed)
	}
}
