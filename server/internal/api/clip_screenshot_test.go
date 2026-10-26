package api

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// v0.14.0 / 整页截图（扩展在全页快照模式下滚动拼接 → 随剪藏请求上行 → 服务端作为**附件**入库
// 并在正文末尾引用）。
//
// 本文件的用例覆盖「可选字段」的全部契约：
//   - 带截图（JPEG / PNG）→ blob 可读、size/sha 一致 + 正文含 `![整页截图](sui://…)`；
//   - `article` 模式带截图 → **整单忽略**（不写 blob、不登记附件、不追加引用）；
//   - 超大截图 / 非法 base64 / 非图片字节 → **忽略该字段**，笔记仍照常建立；
//   - 无 screenshot 字段 → 与今天**逐字节一致**（正文与附件都不变）。

// shotPNGBytes 造一段带 PNG 魔数的假图（内容足够长，避免被当成空体）。
func shotPNGBytes(tag string) []byte {
	out := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
	return append(out, []byte(tag)...)
}

// shotJPEGBytes 造一段带 JPEG 魔数（FF D8 FF）的假图。
func shotJPEGBytes(tag string) []byte {
	out := []byte{0xFF, 0xD8, 0xFF, 0xE0}
	return append(out, []byte(tag)...)
}

// clipWithScreenshot 提交一次剪藏：`screenshot` 为 nil 时不发送该字段
// （用于断言「无截图字段 → 与今天一致」）。
func clipWithScreenshot(
	t *testing.T, srv *Server, token, pageURL, html, mode string, shot map[string]any,
) clipResp {
	t.Helper()
	payload := map[string]any{"url": pageURL, "html": html}
	if mode != "" {
		payload["mode"] = mode
	}
	if shot != nil {
		payload["screenshot"] = shot
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
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

// findScreenshotAttachment 从拉回的笔记里挑出整页截图附件（按展示名判定）。
func findScreenshotAttachment(t *testing.T, note pulledNote) pulledAttachment {
	t.Helper()
	for _, att := range note.Attachments {
		if att.Filename == "整页截图.jpg" || att.Filename == "整页截图.png" {
			return att
		}
	}
	t.Fatalf("笔记里没有整页截图附件：%+v", note.Attachments)
	return pulledAttachment{}
}

const shotTestPNGHTML = `<html><head><title>带截图页</title></head><body><article>` +
	`<h1>标题</h1><p>正文段落，用于命中正文容器并生成 Markdown。</p></article></body></html>`

// TestClipScreenshotStoredAsAttachment：带截图 → blob 入库（size/sha 一致、字节可读回）
// + 附件映射登记 + 正文末尾含 `![整页截图](sui://<sha>)`。
func TestClipScreenshotStoredAsAttachment(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	for _, tc := range []struct {
		name     string
		data     []byte
		filename string
	}{
		{name: "jpeg", data: shotJPEGBytes("shot-jpeg-payload"), filename: "整页截图.jpg"},
		{name: "png", data: shotPNGBytes("shot-png-payload"), filename: "整页截图.png"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp := clipWithScreenshot(t, srv, token,
				"https://example.com/shot-"+tc.name, shotTestPNGHTML, "snapshot",
				map[string]any{
					"filename":   tc.filename,
					"dataBase64": base64.StdEncoding.EncodeToString(tc.data),
				})
			note := pullNote(t, srv, token, resp.NoteID)

			shotHash := sha256Hex(tc.data)
			// 1) M16 / FR-83：snapshot 正文开头是网页原件引用；截图不再追加到正文
			//    （原件是主呈现），但截图附件仍保留，供 WebView 不可用时降级。
			if !strings.HasPrefix(note.Content, "[网页原件](sui://webclip/") {
				t.Fatalf("正文应以网页原件引用开头，实际开头 %q", headOf(note.Content, 80))
			}
			if strings.Contains(note.Content, "![整页截图]") {
				t.Fatalf("有网页原件时正文不应再追加截图：%q", tailOf(note.Content, 160))
			}
			// 来源行仍在（既有行为不被破坏）。
			if !strings.Contains(note.Content, "> 来源：[") {
				t.Fatalf("来源行应仍在正文中，实际开头 %q", headOf(note.Content, 80))
			}

			// 2) blob 落在内容寻址存储里，字节一致、长度一致。
			got, err := readBlob(srv, shotHash)
			if err != nil {
				t.Fatalf("截图 blob 应可读：%v", err)
			}
			if !bytes.Equal(got, tc.data) {
				t.Fatalf("blob 字节不一致：%q", got)
			}

			// 3) 附件映射：展示名 / 大类 / 字节数 / sha / 存储引用一致。
			att := findScreenshotAttachment(t, note)
			if att.Filename != tc.filename {
				t.Fatalf("展示名应为 %q，实际 %q", tc.filename, att.Filename)
			}
			if att.MimeKind != "image" {
				t.Fatalf("mimeKind 应为 image，实际 %q", att.MimeKind)
			}
			if att.ByteSize != len(tc.data) {
				t.Fatalf("byteSize 应为 %d，实际 %d", len(tc.data), att.ByteSize)
			}
			if att.SHA256 != shotHash || att.StorageRef != shotHash {
				t.Fatalf("sha/storageRef 应为 %s，实际 %s / %s", shotHash, att.SHA256, att.StorageRef)
			}
			if !strings.HasPrefix(att.ID, "att-") {
				t.Fatalf("附件 id 应沿用 att- 前缀风格，实际 %q", att.ID)
			}
			// 4) 引用计数：附件映射落库后该 blob 恰被引用一次。
			if n, _ := srv.store.BlobRefCount(shotHash); n != 1 {
				t.Fatalf("截图 blob 引用计数应为 1，实际 %d", n)
			}
		})
	}
}

// TestClipScreenshotIgnoredInArticleMode：`article` 模式带截图 → 整单忽略
// （不写 blob、不登记附件、不追加引用），笔记照常建立。
//
// 语义说明：截图**只在快照模式接受**。用户显式选了「智能提取正文」，笔记末尾多出一张
// 整页图既不符合预期，也不是他要的内容；扩展侧同样只在快照模式采集（双保险）。
func TestClipScreenshotIgnoredInArticleMode(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	data := shotJPEGBytes("article-mode-shot")
	resp := clipWithScreenshot(t, srv, token,
		"https://example.com/article-shot", shotTestPNGHTML, "article",
		map[string]any{
			"filename":   "整页截图.jpg",
			"dataBase64": base64.StdEncoding.EncodeToString(data),
		})
	if resp.Mode != "article" {
		t.Fatalf("用例前提不成立：mode=%q", resp.Mode)
	}
	note := pullNote(t, srv, token, resp.NoteID)

	if strings.Contains(note.Content, "sui://") {
		t.Fatalf("article 模式不得追加截图引用：%q", note.Content)
	}
	if strings.Contains(note.Content, "![整页截图]") {
		t.Fatalf("article 模式不得出现截图引用：%q", note.Content)
	}
	for _, att := range note.Attachments {
		if att.Filename == "整页截图.jpg" {
			t.Fatalf("article 模式不得登记截图附件：%+v", att)
		}
	}
	// 连 blob 都不该写（不做「先存后弃」）。
	if _, err := readBlob(srv, sha256Hex(data)); err == nil {
		t.Fatal("article 模式不应把截图写入 blob 存储")
	}
}

// TestClipScreenshotOversizedIgnored：超大截图 → 忽略该字段，笔记仍建立且**不 500**。
//
// 刻意只让**截图载荷**超限、整包仍在 maxBodyBytes 之内：真正的风险场景是「扩展没拦住
// 大图」——若服务端不做这道闸门，请求体超限会触发 413，**整单剪藏失败**。本用例断言的
// 正是「截图被丢掉、笔记照常入库」。
func TestClipScreenshotOversizedIgnored(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	// 4.5 MiB 原始字节 → base64 文本 6 MiB（> maxScreenshotBase64Chars ≈ 5.75 MiB，
	// 且整包仍在 maxBodyBytes 之内 → 不触发 413，只有截图被忽略）。
	huge := make([]byte, 4*1024*1024+512*1024)
	copy(huge, shotPNGBytes(""))
	b64 := base64.StdEncoding.EncodeToString(huge)

	resp := clipWithScreenshot(t, srv, token,
		"https://example.com/huge-shot", shotTestPNGHTML, "snapshot",
		map[string]any{"filename": "整页截图.png", "dataBase64": b64})
	if !resp.OK || resp.Version != 1 {
		t.Fatalf("超限截图应被忽略而非让整单失败：ok=%v v=%d", resp.OK, resp.Version)
	}
	note := pullNote(t, srv, token, resp.NoteID)
	if strings.Contains(note.Content, "![整页截图]") {
		t.Fatalf("超限截图不得追加引用：%q", tailOf(note.Content, 160))
	}
	for _, att := range note.Attachments {
		if att.MimeKind == "image" || strings.Contains(att.Filename, "整页截图") {
			t.Fatalf("超限截图不得登记附件：%+v", note.Attachments)
		}
	}
	if len(note.Attachments) != 1 || note.Attachments[0].MimeKind != "webclip" {
		t.Fatalf("应只登记网页原件附件：%+v", note.Attachments)
	}
	// 但笔记主体照常入库。
	if !strings.Contains(note.Content, "正文段落") {
		t.Fatalf("笔记正文应照常入库：%q", note.Content)
	}
	if _, err := readBlob(srv, sha256Hex(huge)); err == nil {
		t.Fatal("超限截图不得写入 blob 存储")
	}
}

// TestClipScreenshotMalformedIgnored：base64 非法 / 空 / 非图片魔数 → 一律忽略，笔记仍建立。
func TestClipScreenshotMalformedIgnored(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	cases := []struct {
		name string
		shot map[string]any
	}{
		{name: "非法 base64 字符", shot: map[string]any{
			"filename": "整页截图.jpg", "dataBase64": "!!!not-base64!!!",
		}},
		{name: "长度不合法的 base64", shot: map[string]any{
			"filename": "整页截图.jpg", "dataBase64": "QUF",
		}},
		{name: "空 base64", shot: map[string]any{
			"filename": "整页截图.jpg", "dataBase64": "",
		}},
		{name: "缺 dataBase64 字段", shot: map[string]any{
			"filename": "整页截图.jpg",
		}},
		{name: "base64 合法但不是图片", shot: map[string]any{
			"filename":   "整页截图.jpg",
			"dataBase64": base64.StdEncoding.EncodeToString([]byte("这不是图片，只是一段文本。")),
		}},
		{name: "声明 jpg 实际是 gif", shot: map[string]any{
			"filename":   "整页截图.jpg",
			"dataBase64": base64.StdEncoding.EncodeToString([]byte("GIF89a-not-supported")),
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp := clipWithScreenshot(t, srv, token,
				"https://example.com/bad-shot", shotTestPNGHTML, "snapshot", tc.shot)
			if !resp.OK || resp.Version != 1 {
				t.Fatalf("坏截图应被忽略而非让整单失败：ok=%v v=%d", resp.OK, resp.Version)
			}
			note := pullNote(t, srv, token, resp.NoteID)
			if strings.Contains(note.Content, "![整页截图]") {
				t.Fatalf("坏截图不得追加引用：%q", tailOf(note.Content, 160))
			}
			for _, att := range note.Attachments {
				if att.MimeKind == "image" || strings.Contains(att.Filename, "整页截图") {
					t.Fatalf("坏截图不得登记附件：%+v", note.Attachments)
				}
			}
			if len(note.Attachments) != 1 || note.Attachments[0].MimeKind != "webclip" {
				t.Fatalf("应只登记网页原件附件：%+v", note.Attachments)
			}
			if !strings.Contains(note.Content, "正文段落") {
				t.Fatalf("笔记正文应照常入库：%q", note.Content)
			}
		})
	}
}

// TestClipScreenshotAbsentUnchanged：**不带** screenshot 字段时，产物与今天逐字节一致
// （正文、来源行、附件集合都不变）。
//
// 用同一次会话的两次剪藏互比：两次输入完全相同，只差 mode 字段的显式程度
// （第一次不带 mode、第二次显式 "snapshot"）——两者的净化结果同义，故正文必须一致。
func TestClipScreenshotAbsentUnchanged(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	// 1) 完全不带 screenshot、也不带 mode（等价于今天扩展 article 路径之外的既有无参调用）。
	plain := clipWithScreenshot(t, srv, token,
		"https://example.com/no-shot", shotTestPNGHTML, "", nil)
	// 2) 显式 article：同一段 HTML 的 article 产物必须与无参调用逐字节一致。
	art := clipWithScreenshot(t, srv, token,
		"https://example.com/no-shot", shotTestPNGHTML, "article", nil)

	plainNote := pullNote(t, srv, token, plain.NoteID)
	artNote := pullNote(t, srv, token, art.NoteID)

	if plainNote.Content != artNote.Content {
		t.Fatalf("无 screenshot 字段时 article 正文应逐字节一致：\nplain=%q\narticle=%q",
			plainNote.Content, artNote.Content)
	}
	if strings.Contains(artNote.Content, "sui://") {
		t.Fatalf("无 screenshot 字段时不得出现 sui:// 引用：%q", artNote.Content)
	}
	if len(plainNote.Attachments) != 0 || len(artNote.Attachments) != 0 {
		t.Fatalf("无 screenshot 字段时不应产生附件：%+v / %+v",
			plainNote.Attachments, artNote.Attachments)
	}
	// 来源行仍在（既有行为）。
	if !strings.HasPrefix(artNote.Content, "> 来源：[https://example.com/no-shot](") {
		t.Fatalf("来源行不应变化：%q", headOf(artNote.Content, 80))
	}
}

// TestClipScreenshotFilenameFallback：展示名缺失 / 全空白 → 用缺省名（不让附件无名字）。
func TestClipScreenshotFilenameFallback(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	data := shotJPEGBytes("fallback-name")
	resp := clipWithScreenshot(t, srv, token,
		"https://example.com/name-shot", shotTestPNGHTML, "snapshot",
		map[string]any{
			"filename":   "   ",
			"dataBase64": base64.StdEncoding.EncodeToString(data),
		})
	note := pullNote(t, srv, token, resp.NoteID)
	if att := findScreenshotAttachment(t, note); att.Filename != "整页截图.jpg" {
		t.Fatalf("空白展示名应回落缺省名，实际 %q", att.Filename)
	}
}

// TestClipScreenshotRejectsEmptyFilenameOnly：只有 filename、没有字节 → 忽略（不当附件）。
func TestClipScreenshotRejectsEmptyFilenameOnly(t *testing.T) {
	srv := newTestServer(t)
	token := register(t, srv)

	resp := clipWithScreenshot(t, srv, token,
		"https://example.com/empty-shot", shotTestPNGHTML, "snapshot",
		map[string]any{"filename": "整页截图.jpg"})
	note := pullNote(t, srv, token, resp.NoteID)
	for _, att := range note.Attachments {
		if att.MimeKind == "image" || strings.Contains(att.Filename, "整页截图") {
			t.Fatalf("无字节的截图不得登记附件：%+v", note.Attachments)
		}
	}
}

// head / tail 是失败信息里的截断辅助（正文可能很长，整段打印淹没有效信息）。
func headOf(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}

func tailOf(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return "…" + s[len(s)-n:]
}
