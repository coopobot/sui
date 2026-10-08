package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// ---- M6 共用测试辅助（FR-37 / FR-38 / FR-39）----

// testMediaClient 返回**不带出网地址闸门**的媒体客户端，仅供本文件的本地化用例使用。
//
// 这些用例用 127.0.0.1 的 httptest 服务器提供图片，而生产默认客户端会在拨号时拒绝回环 /
// 私网地址（M10-T27，clip/guard.go）。闸门与生产默认路径由 clip/guard_test.go 与
// api/m10_clip_test.go 覆盖，这里只是把本地服务器让进来。
func testMediaClient() *http.Client {
	return &http.Client{Timeout: 5 * time.Second}
}

type clipResp struct {
	OK                bool   `json:"ok"`
	NoteID            string `json:"noteId"`
	Title             string `json:"title"`
	Version           int    `json:"version"`
	URL               string `json:"url"`
	Mode              string `json:"mode"`
	UnlocalizedImages int    `json:"unlocalizedImages"`
}

type pulledAttachment struct {
	ID         string `json:"id"`
	Filename   string `json:"filename"`
	MimeKind   string `json:"mimeKind"`
	ByteSize   int    `json:"byteSize"`
	SHA256     string `json:"sha256"`
	StorageRef string `json:"storageRef"`
	IsDeleted  bool   `json:"isDeleted"`
}

type pulledNote struct {
	ID          string             `json:"id"`
	Title       string             `json:"title"`
	Content     string             `json:"content"`
	Attachments []pulledAttachment `json:"attachments"`
}

// clipNote 提交一次剪藏并返回响应体；mode 为空时不发送该字段（走缺省 article）。
func clipNote(t *testing.T, srv *Server, token, pageURL, html, mode string) clipResp {
	t.Helper()
	payload := map[string]string{"url": pageURL, "html": html}
	if mode != "" {
		payload["mode"] = mode
	}
	body, _ := json.Marshal(payload)
	rec := authReq(srv, token, http.MethodPost, "/api/v1/clips", body)
	if rec.Code != http.StatusOK {
		t.Fatalf("clip failed: %d %s", rec.Code, rec.Body.String())
	}
	var resp clipResp
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	return resp
}

// pullNotes 拉取全部笔记（含附件映射）。
func pullNotes(t *testing.T, srv *Server, token string) []pulledNote {
	t.Helper()
	rec := authReq(srv, token, http.MethodGet, "/api/v1/sync/pull?since=1970-01-01T00:00:00Z", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("pull failed: %d %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Notes []pulledNote `json:"notes"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	return resp.Notes
}

// pullNote 按 id 取回单条笔记。
func pullNote(t *testing.T, srv *Server, token, id string) pulledNote {
	t.Helper()
	for _, n := range pullNotes(t, srv, token) {
		if n.ID == id {
			return n
		}
	}
	t.Fatalf("note %q not found in pull result", id)
	return pulledNote{}
}

// newImageServer 起一个仅服务给定路径的测试图床；未注册路径返回 404（用于降级用例）。
func newImageServer(t *testing.T, files map[string][]byte) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	for p, data := range files {
		data := data
		mux.HandleFunc(p, func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write(data)
		})
	}
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// readBlob 读回内容寻址存储中的字节。
func readBlob(srv *Server, hash string) ([]byte, error) {
	rc, err := srv.blobs.Open(hash)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// ---- M6 用例 ----

// TestClipSnapshotMode：snapshot 保留整页结构与原文顺序、剔除非内容节点；
// article 缺省向后兼容（FR-37 / AC-102 / AC-103）。
func TestClipSnapshotMode(t *testing.T) {
	srv := newTestServer(t)
	srv.SetMediaClient(testMediaClient())
	token := register(t, srv)

	html := `<!DOCTYPE html><html><head><title>快照测试页</title></head><body>
<nav><a href="/home">首页导航</a></nav>
<header><h1>站点页眉</h1></header>
<article>
<h2>文章小标题</h2>
<p>这是第一段正文内容，用于提升文本密度以命中正文容器。</p>
<figure><figcaption>图片说明文字</figcaption></figure>
<table><thead><tr><th>列A</th><th>列B</th></tr></thead>
<tbody><tr><td>单元1</td><td>单元2</td></tr></tbody></table>
</article>
<footer>页脚版权信息</footer>
<script>var track=true;</script>
</body></html>`

	// 1) snapshot：整页保结构（导航 / 页眉 / 页脚 / 表格 / 图注俱在），剔除 script。
	snap := clipNote(t, srv, token, "https://example.com/snapshot", html, "snapshot")
	if snap.Mode != "snapshot" {
		t.Fatalf("expected mode=snapshot, got %q", snap.Mode)
	}
	snapNote := pullNote(t, srv, token, snap.NoteID)
	for _, want := range []string{"首页导航", "站点页眉", "页脚版权信息", "图片说明文字", "列A", "单元1"} {
		if !strings.Contains(snapNote.Content, want) {
			t.Fatalf("snapshot must keep %q; content=%q", want, snapNote.Content)
		}
	}
	if strings.Contains(snapNote.Content, "var track") {
		t.Fatalf("snapshot must drop <script>; content=%q", snapNote.Content)
	}
	// 原文顺序：导航 → 页眉 → 正文 → 页脚。
	iNav := strings.Index(snapNote.Content, "首页导航")
	iHead := strings.Index(snapNote.Content, "站点页眉")
	iBody := strings.Index(snapNote.Content, "文章小标题")
	iFoot := strings.Index(snapNote.Content, "页脚版权信息")
	if !(iNav < iHead && iHead < iBody && iBody < iFoot) {
		t.Fatalf("snapshot must preserve source order, got idx %d/%d/%d/%d", iNav, iHead, iBody, iFoot)
	}

	// 2) 缺省（未带 mode）→ article：剔除导航 / 页眉 / 页脚，仅留正文。
	art := clipNote(t, srv, token, "https://example.com/article-mode", html, "")
	if art.Mode != "article" {
		t.Fatalf("expected default mode=article, got %q", art.Mode)
	}
	artNote := pullNote(t, srv, token, art.NoteID)
	if !strings.Contains(artNote.Content, "文章小标题") || !strings.Contains(artNote.Content, "列A") {
		t.Fatalf("article must keep main content; content=%q", artNote.Content)
	}
	for _, drop := range []string{"首页导航", "站点页眉", "页脚版权信息"} {
		if strings.Contains(artNote.Content, drop) {
			t.Fatalf("article mode must drop %q; content=%q", drop, artNote.Content)
		}
	}

	// 3) mode 大小写不敏感；未知取值回落 article（BR-37.4）。
	if got := clipNote(t, srv, token, "https://example.com/case-mode", html, "Snapshot"); got.Mode != "snapshot" {
		t.Fatalf("mode should be case-insensitive, got %q", got.Mode)
	}
	if got := clipNote(t, srv, token, "https://example.com/unknown-mode", html, "wide"); got.Mode != "article" {
		t.Fatalf("unknown mode must fall back to article, got %q", got.Mode)
	}
}

// TestClipMediaLocalization：图片下载 → sha256 入库 → 正文改 sui://；
// 同图去重；data-src / srcset / 相对 URL 解析（FR-38 / AC-105~107）。
func TestClipMediaLocalization(t *testing.T) {
	srv := newTestServer(t)
	srv.SetMediaClient(testMediaClient())
	token := register(t, srv)

	pngA := []byte("\x89PNG\r\n\x1a\nAAAA-localization-a")
	pngB := []byte("\x89PNG\r\n\x1a\nBBBB-localization-b")
	pngC := []byte("\x89PNG\r\n\x1a\nCCCC-localization-c")
	imgSrv := newImageServer(t, map[string][]byte{
		"/a.png": pngA,
		"/b.png": pngB,
		"/c.png": pngC,
	})

	pageURL := imgSrv.URL + "/page"
	html := `<html><head><title>图文章</title></head><body><article>
<p>带图片的正文。</p>
<img src="/a.png" alt="相对URL图" width="600">
<img data-src="/b.png" alt="懒加载图">
<img src="" srcset="/a.png 1x, /c.png 2x" alt="srcset图">
<img src="/a.png" alt="重复引用图">
</article></body></html>`

	resp := clipNote(t, srv, token, pageURL, html, "snapshot")
	if resp.UnlocalizedImages != 0 {
		t.Fatalf("expected 0 unlocalized, got %d", resp.UnlocalizedImages)
	}
	note := pullNote(t, srv, token, resp.NoteID)

	hashA, hashB, hashC := sha256Hex(pngA), sha256Hex(pngB), sha256Hex(pngC)
	for _, h := range []string{hashA, hashB, hashC} {
		if !strings.Contains(note.Content, "sui://"+h) {
			t.Fatalf("content should reference sui://%s; content=%q", h, note.Content)
		}
	}
	// 4 个 <img>、a.png 被引用两次 → 仅登记 3 个附件（内容寻址天然去重）。
	if len(note.Attachments) != 3 {
		t.Fatalf("expected 3 deduped attachments, got %d (%+v)", len(note.Attachments), note.Attachments)
	}
	for _, att := range note.Attachments {
		if att.MimeKind != "image" {
			t.Fatalf("expected mimeKind=image, got %q", att.MimeKind)
		}
		if att.StorageRef != att.SHA256 || len(att.SHA256) != 64 {
			t.Fatalf("storageRef must equal 64-hex sha256, got ref=%q sha=%q", att.StorageRef, att.SHA256)
		}
	}
	// 每个 blob 恰被引用一次。
	for _, h := range []string{hashA, hashB, hashC} {
		if n, _ := srv.store.BlobRefCount(h); n != 1 {
			t.Fatalf("expected refcount=1 for %s, got %d", h, n)
		}
	}
	// 字节自持：内容寻址存储可读回原字节。
	got, err := readBlob(srv, hashA)
	if err != nil {
		t.Fatalf("localized blob must be stored: %v", err)
	}
	if !bytes.Equal(got, pngA) {
		t.Fatalf("stored blob bytes mismatch: %q", got)
	}
	// 本地化成功后，正文不得残留原图外链。
	for _, dangling := range []string{"/a.png", "/b.png", "/c.png", imgSrv.URL + "/a.png"} {
		if strings.Contains(note.Content, dangling) {
			t.Fatalf("localized images must not keep %q; content=%q", dangling, note.Content)
		}
	}
	// alt 与 {width} 语法保留（BR-38.7）。
	if !strings.Contains(note.Content, "![相对URL图](sui://") || !strings.Contains(note.Content, "{width=600}") {
		t.Fatalf("alt/width must be preserved; content=%q", note.Content)
	}
}

// TestClipMediaFailureDegrade：单图失败保留绝对 URL + 整篇仍入库 + 「未本地化」计数（FR-38 / AC-108）。
func TestClipMediaFailureDegrade(t *testing.T) {
	srv := newTestServer(t)
	srv.SetMediaClient(testMediaClient())
	token := register(t, srv)

	pngOK := []byte("\x89PNG\r\n\x1a\nOK-degrade")
	imgSrv := newImageServer(t, map[string][]byte{"/ok.png": pngOK})
	// /missing.png 未注册 → 图床返回 404。

	pageURL := imgSrv.URL + "/page"
	html := `<html><head><title>降级页</title></head><body><article>
<p>一张能下、一张下不了。</p>
<img src="/ok.png" alt="好图">
<img src="/missing.png" alt="坏图">
</article></body></html>`

	resp := clipNote(t, srv, token, pageURL, html, "snapshot")
	if !resp.OK || resp.Version != 1 {
		t.Fatalf("note must still be stored despite one image failing: ok=%v v=%d", resp.OK, resp.Version)
	}
	if resp.UnlocalizedImages != 1 {
		t.Fatalf("expected unlocalizedImages=1, got %d", resp.UnlocalizedImages)
	}
	note := pullNote(t, srv, token, resp.NoteID)

	hashOK := sha256Hex(pngOK)
	if !strings.Contains(note.Content, "sui://"+hashOK) {
		t.Fatalf("downloadable image must be localized; content=%q", note.Content)
	}
	absMissing := imgSrv.URL + "/missing.png"
	if !strings.Contains(note.Content, absMissing) {
		t.Fatalf("failed image must keep absolute URL %q; content=%q", absMissing, note.Content)
	}
	// 仅成功图登记附件映射。
	if len(note.Attachments) != 1 {
		t.Fatalf("expected 1 attachment (only the successful image), got %d (%+v)", len(note.Attachments), note.Attachments)
	}
	if n, _ := srv.store.BlobRefCount(hashOK); n != 1 {
		t.Fatalf("expected refcount=1 for ok blob, got %d", n)
	}
}

// TestClipOfflineReadable：原站 / 图片 URL 不可达后，笔记正文与图片仍可读（FR-39 / AC-110）。
func TestClipOfflineReadable(t *testing.T) {
	srv := newTestServer(t)
	srv.SetMediaClient(testMediaClient())
	token := register(t, srv)

	png := []byte("\x89PNG\r\n\x1a\nOFFLINE-self-contained")
	imgSrv := newImageServer(t, map[string][]byte{"/hero.png": png})
	pageURL := imgSrv.URL + "/post"

	html := `<html><head><title>会下线的页面</title></head><body><article>
<h2>正文标题</h2><p>这段正文必须自持。</p>
<img src="/hero.png" alt="主图">
</article></body></html>`

	resp := clipNote(t, srv, token, pageURL, html, "snapshot")
	if resp.UnlocalizedImages != 0 {
		t.Fatalf("expected 0 unlocalized, got %d", resp.UnlocalizedImages)
	}

	// 原站下线：关闭图床（此后任何图片外链都不可达）。
	imgSrv.Close()

	note := pullNote(t, srv, token, resp.NoteID)
	if !strings.Contains(note.Content, "这段正文必须自持") {
		t.Fatalf("note text must be self-contained; content=%q", note.Content)
	}
	hash := sha256Hex(png)
	if !strings.Contains(note.Content, "sui://"+hash) {
		t.Fatalf("image must be self-contained (sui://); content=%q", note.Content)
	}
	// 正文不得再持有原站图片地址（来源链接除外，BR-39.2）。
	if strings.Contains(note.Content, "/hero.png") {
		t.Fatalf("content must not keep the origin image URL; content=%q", note.Content)
	}
	// 字节自持：离线后仍可从内容寻址存储读回原字节。
	got, err := readBlob(srv, hash)
	if err != nil {
		t.Fatalf("self-hosted blob must be readable offline: %v", err)
	}
	if !bytes.Equal(got, png) {
		t.Fatalf("self-hosted blob bytes mismatch: %q", got)
	}
	if len(note.Attachments) != 1 || note.Attachments[0].SHA256 != hash {
		t.Fatalf("expected 1 attachment mapping to %s, got %+v", hash, note.Attachments)
	}
}
