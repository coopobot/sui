package clip

import (
	"strings"
	"testing"
)

// M10-T30：剪藏 Markdown 构造的转义门禁。
//
// 页面提供的 `alt` / `src` / `href` 若不转义，`]` 会截断图片标签、`)` 会截断目标位，
// 剩余内容漏成正文（极端情况下可注入结构）。

func TestEscapeMarkdownText(t *testing.T) {
	cases := map[string]string{
		"普通文字":         "普通文字",
		"a]b":          `a\]b`,
		"[x](y)":       `\[x\](y)`,
		`back\slash`:   `back\\slash`,
		"line\nbreak":  "line break",
		"carriage\r":   "carriage ",
		"sui://abc123": "sui://abc123",
	}
	for in, want := range cases {
		if got := EscapeMarkdownText(in); got != want {
			t.Errorf("EscapeMarkdownText(%q) = %q，期望 %q", in, got, want)
		}
	}
}

func TestEscapeMarkdownURL(t *testing.T) {
	cases := map[string]string{
		"https://a.example/x":    "https://a.example/x",
		"https://a.example/a)b":  `https://a.example/a\)b`,
		"https://a.example/a(b)": `https://a.example/a\(b\)`,
		"https://a.example/a b":  "https://a.example/a%20b",
		"https://a.example/a\nb": "https://a.example/ab",
		"sui://0123":             "sui://0123",
	}
	for in, want := range cases {
		if got := EscapeMarkdownURL(in); got != want {
			t.Errorf("EscapeMarkdownURL(%q) = %q，期望 %q", in, got, want)
		}
	}
}

// 端到端：净化页面时，链接 / 图片的属性必须已转义（不会被 `]` / `)` 截断）。
func TestPurifyEscapesLinkAndImageAttributes(t *testing.T) {
	html := `<html><body><article><h1>标题</h1><p>正文</p>` +
		`<a href="https://a.example/p?a=1)2">链接</a>` +
		`<img src="https://a.example/i.png" alt="名字]带括号)">` +
		`</article></body></html>`

	res, err := Purify(html, "https://page.example/a", "article")
	if err != nil {
		t.Fatalf("Purify 失败：%v", err)
	}
	if !strings.Contains(res.Content, `[链接](https://a.example/p?a=1\)2)`) {
		t.Errorf("链接目标应转义 `)`，实际内容：\n%s", res.Content)
	}
	// alt 走**文本位**：只转义 `]`（`(` / `)` 在文本位没有结构含义，不该被改写）；
	// src 走**目标位**：转义 `)`。故实际形态是 `![名字\]带括号)](...)`。
	if !strings.Contains(res.Content, `![名字\]带括号)](https://a.example/i.png)`) {
		t.Errorf("图片 alt 应转义 `]`、src 不应被 alt 里的 `)` 影响，实际内容：\n%s", res.Content)
	}
}
