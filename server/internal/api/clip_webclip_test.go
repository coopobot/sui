package api

import (
	"bytes"
	"strings"
	"testing"
)

// M16 / FR-83 / FR-86：snapshot 双产物（Markdown + 单文件 HTML 原件）与默认标签。
//
// 覆盖：
//   - snapshot → 正文头部有 `[网页原件](sui://webclip/<sha>)`；
//   - 原件附件 mimeKind=webclip，字节可读回；
//   - 原件保留 DOM / style / 图片 sui://，剔除 script / on* / iframe；
//   - 注入 CSP；article 模式不产生原件；
//   - 剪藏默认挂「网页剪藏」标签，同名复用。
func TestClipSnapshotCreatesWebClipAndDefaultTag(t *testing.T) {
	srv := newTestServer(t)
	srv.SetMediaClient(testMediaClient())
	token := register(t, srv)

	png := []byte("\x89PNG\r\n\x1a\nWEBCLIP-IMAGE")
	imgSrv := newImageServer(t, map[string][]byte{"/p.png": png})
	pageURL := imgSrv.URL + "/page"
	html := `<html><head><title>原件页</title><style>.hero{color:red}</style></head><body>
<div class="hero" style="text-align:center" onclick="evil()">居中内容</div>
<script>alert(1)</script><iframe src="https://evil.example"></iframe>
<img src="/p.png" alt="图">
</body></html>`

	resp := clipNote(t, srv, token, pageURL, html, "snapshot")
	note := pullNote(t, srv, token, resp.NoteID)

	// 1) 正本头部是网页原件引用。
	if !strings.HasPrefix(note.Content, "[网页原件](sui://webclip/") {
		t.Fatalf("正文应以网页原件引用开头，实际 %q", headOf(note.Content, 100))
	}
	// 2) 找到 webclip 附件并读回字节。
	var webclip pulledAttachment
	for _, att := range note.Attachments {
		if att.MimeKind == "webclip" {
			webclip = att
		}
	}
	if webclip.SHA256 == "" {
		t.Fatalf("缺少 webclip 附件：%+v", note.Attachments)
	}
	if !strings.Contains(note.Content, "sui://webclip/"+webclip.SHA256) {
		t.Fatalf("正文引用与附件 sha 不一致：%q / %s", note.Content, webclip.SHA256)
	}
	data, err := readBlob(srv, webclip.SHA256)
	if err != nil {
		t.Fatalf("webclip blob 应可读：%v", err)
	}
	htmlOut := string(data)
	if !strings.HasPrefix(htmlOut, "<!DOCTYPE html>") {
		t.Fatalf("原件应带 doctype：%q", headOf(htmlOut, 60))
	}
	if !strings.Contains(htmlOut, "居中内容") || !strings.Contains(htmlOut, "text-align:center") {
		t.Fatalf("原件应保留 DOM 与内联样式：%q", htmlOut)
	}
	if !strings.Contains(htmlOut, "sui://"+sha256Hex(png)) {
		t.Fatalf("原件图片应改写为 sui://：%q", htmlOut)
	}
	for _, banned := range []string{"<script", "onclick=", "<iframe", "alert(1)"} {
		if strings.Contains(htmlOut, banned) {
			t.Fatalf("原件不得包含 %q：%q", banned, htmlOut)
		}
	}
	if !strings.Contains(htmlOut, "Content-Security-Policy") ||
		!strings.Contains(htmlOut, "default-src") ||
		!strings.Contains(htmlOut, "img-src data:") {
		t.Fatalf("原件应注入 CSP：%q", htmlOut)
	}
	if !bytes.Contains(data, []byte("网页原件")) && !bytes.Contains(data, []byte("居中内容")) {
		t.Fatalf("原件内容异常：%q", htmlOut)
	}

	// 3) 默认标签「网页剪藏」。
	tagsByNote, err := srv.store.ListNoteTagsForNotes([]string{resp.NoteID})
	if err != nil {
		t.Fatal(err)
	}
	tagIDs := tagsByNote[resp.NoteID]
	if len(tagIDs) != 1 {
		t.Fatalf("应挂 1 个默认标签，实际 %v", tagIDs)
	}
	tag, err := srv.store.GetTag(tagIDs[0])
	if err != nil || tag == nil {
		t.Fatalf("默认标签应存在：%v / %+v", err, tag)
	}
	if tag.Name != "网页剪藏" {
		t.Fatalf("默认标签名应为 网页剪藏，实际 %q", tag.Name)
	}

	// 4) 第二次剪藏复用同一标签（同名幂等）。
	resp2 := clipNote(t, srv, token, pageURL, html, "snapshot")
	tags2, _ := srv.store.ListNoteTagsForNotes([]string{resp2.NoteID})
	if len(tags2[resp2.NoteID]) != 1 || tags2[resp2.NoteID][0] != tagIDs[0] {
		t.Fatalf("默认标签应复用同一 id：first=%v second=%v", tagIDs, tags2[resp2.NoteID])
	}
}

func TestClipArticleDoesNotCreateWebClip(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	resp := clipNote(t, srv, token, "https://example.com/article", shotTestPNGHTML, "article")
	note := pullNote(t, srv, token, resp.NoteID)
	if strings.Contains(note.Content, "sui://webclip/") {
		t.Fatalf("article 模式不得产生网页原件：%q", note.Content)
	}
	for _, att := range note.Attachments {
		if att.MimeKind == "webclip" {
			t.Fatalf("article 模式不得登记 webclip 附件：%+v", att)
		}
	}
}
