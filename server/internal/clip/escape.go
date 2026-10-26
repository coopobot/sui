package clip

import "strings"

// Markdown 结构性字符转义（M10-T30 / input-validation.md §9）。
//
// 剪藏把**页面提供的字符串**合成 Markdown 正本：`alt` 进**文本位**、`src` / `href` 进**目标位**。
// 不转义时，一个 `]` 或 `)` 就能截断链接 / 图片，把剩余内容漏成正文甚至注入结构。
//
// 只处理**结构性**字符，不做「全量 Markdown 转义」：页面正文里的 `*` / `#` 本来就该按
// Markdown 语义呈现，过度转义会改变剪藏结果（正本即 Markdown，守 BR-23.1）。

var mdTextEscaper = strings.NewReplacer(
	`\`, `\\`,
	`[`, `\[`,
	`]`, `\]`,
	"\n", " ",
	"\r", " ",
)

var mdURLEscaper = strings.NewReplacer(
	`\`, `\\`,
	`(`, `\(`,
	`)`, `\)`,
	" ", "%20",
	"\n", "",
	"\r", "",
)

// EscapeMarkdownText 转义**文本位**（链接 / 图片的显示文字）中的结构性字符。
func EscapeMarkdownText(s string) string { return mdTextEscaper.Replace(s) }

// EscapeMarkdownURL 转义**目标位**（链接 / 图片地址）中的结构性字符。
func EscapeMarkdownURL(s string) string { return mdURLEscaper.Replace(s) }
