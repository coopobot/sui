package api

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// v0.13.2 / BR-08.4 / BR-05.1 / BR-05.4 / AC-264 / AC-265：
// 剪藏来源标记（`notes.source_url`）是「该笔记由网页剪藏产生」的**唯一权威、不可变**标记，
// 必须随 pull 下行；客户端的收件箱判据据此判定，而不是按会被本机 push 改写的 `source_device`。
//
// 本用例复现的是实测缺陷：真 Chrome + 真扩展对新华网做全页快照 → 浮层回「剪藏成功」、
// 服务端 `source_device='clip:web-extension'`，但客户端「收件箱」看不到——因为该笔记
// 一旦被本机 push 过（编辑 / 单项重试 /「全部重新同步」核对补齐），`source_device`
// 就被改写为本机 deviceId，只按它过滤就永久退出收件箱。
type pulledNoteV0132 struct {
	ID           string `json:"id"`
	Content      string `json:"content"`
	Version      int    `json:"version"`
	SourceDevice string `json:"sourceDevice"`
	SourceURL    string `json:"sourceUrl"`
}

func pullV0132(t *testing.T, srv *Server, token string) []pulledNoteV0132 {
	t.Helper()
	rec := authReq(srv, token, http.MethodGet,
		"/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("pull failed: %d %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Notes []pulledNoteV0132 `json:"notes"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	return resp.Notes
}

func findPulledV0132(notes []pulledNoteV0132, id string) (pulledNoteV0132, bool) {
	for _, n := range notes {
		if n.ID == id {
			return n, true
		}
	}
	return pulledNoteV0132{}, false
}

func TestClipSourceURLSurvivesClientPush(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	const pageURL = "https://example.com/clip-marker"
	html := `<html><head><title>剪藏页</title></head><body><article><p>正文内容</p></article></body></html>`
	clip := clipNote(t, srv, token, pageURL, html, "snapshot")

	// 1) 剪藏落库后：pull 净荷带 sourceUrl（AC-264）。
	before, ok := findPulledV0132(pullV0132(t, srv, token), clip.NoteID)
	if !ok {
		t.Fatalf("剪藏笔记 %s 未出现在 pull 结果里", clip.NoteID)
	}
	if before.SourceURL != pageURL {
		t.Fatalf("剪藏笔记的 pull 净荷应带 sourceUrl=%q，实际 %q", pageURL, before.SourceURL)
	}
	if !strings.HasPrefix(before.SourceDevice, "clip:") {
		t.Fatalf("落库时 source_device 应为 clip: 起头，实际 %q", before.SourceDevice)
	}

	// 2) 客户端真实写路径：用**本机 deviceId** push 回去。
	pushBody, _ := json.Marshal(map[string]any{
		"clientId": "device-desktop",
		"items": []map[string]any{{
			"id":           clip.NoteID,
			"title":        "剪藏页（本地改过）",
			"content":      before.Content + "\n\n本地补充",
			"baseVersion":  before.Version,
			"version":      before.Version + 1,
			"sourceDevice": "device-desktop",
		}},
	})
	rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", pushBody)
	if rec.Code != http.StatusOK {
		t.Fatalf("push failed: %d %s", rec.Code, rec.Body.String())
	}
	var pushed struct {
		Results []struct {
			Accepted bool `json:"accepted"`
		} `json:"results"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&pushed); err != nil {
		t.Fatal(err)
	}
	if len(pushed.Results) != 1 || !pushed.Results[0].Accepted {
		t.Fatalf("本机 push 应被接受：%s", rec.Body.String())
	}

	after, _ := findPulledV0132(pullV0132(t, srv, token), clip.NoteID)
	if after.SourceDevice != "device-desktop" {
		t.Fatalf("source_device 语义是「最近一次修改的来源设备」，应被改写为 device-desktop，实际 %q",
			after.SourceDevice)
	}
	if after.SourceURL != pageURL {
		t.Fatalf("sourceUrl 是**不可变**的剪藏来源标记，不得被客户端 push 抹掉：期望 %q，实际 %q",
			pageURL, after.SourceURL)
	}

	// 3) 负例（AC-266）：普通手工笔记不带 sourceUrl。
	manualBody, _ := json.Marshal(map[string]any{
		"clientId": "device-desktop",
		"items": []map[string]any{{
			"id": "note-manual", "title": "手写", "content": "手写正文",
			"baseVersion": 0, "version": 1, "sourceDevice": "device-desktop",
		}},
	})
	if rec := authReq(srv, token, http.MethodPost, "/api/v1/sync/push", manualBody); rec.Code != http.StatusOK {
		t.Fatalf("push manual failed: %d %s", rec.Code, rec.Body.String())
	}
	manual, ok := findPulledV0132(pullV0132(t, srv, token), "note-manual")
	if !ok {
		t.Fatal("手工笔记未出现在 pull 结果里")
	}
	if manual.SourceURL != "" {
		t.Fatalf("普通笔记不应带 sourceUrl，实际 %q", manual.SourceURL)
	}
}
