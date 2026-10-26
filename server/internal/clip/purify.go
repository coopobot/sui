// Package clip 提供网页剪藏的内容净化与 Markdown 转换。
//
// 支持两种模式（M6 / FR-37）：
//   - article（缺省）：类 Readability 启发式选正文主容器，剔除导航 / 侧栏 / 页脚；
//   - snapshot：不做主内容挑选，遍历整页内容节点并保持原文顺序，仅剔除非内容节点。
//
// HTML → Markdown：支持标题 / 段落 / 列表 / 表格 / 链接 / 粗体 / 斜体 / 删除线 /
// 图片（含尺寸）/ 图注 / 代码块 / 引用。
//
// 产物始终以 Markdown 为正本（守 BR-23.1 / BR-37.2）；`snapshot` 模式额外把同一份已本地化
// DOM 序列化为**单文件 HTML 原件**（附件，见 webclip.go，M16 / FR-83），不是第二正本。
// 不做像素级还原（BR-37.3）。媒体本地化见 media.go（FR-38）。
package clip

import (
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

// 剪藏模式（M6 / FR-37）。
const (
	// ModeArticle 类 Readability 启发式选主内容（缺省，BR-37.4 向后兼容）。
	ModeArticle = "article"
	// ModeSnapshot 整页保结构，保持原文顺序（FR-37）。
	ModeSnapshot = "snapshot"
)

// NormalizeMode 规整 mode 取值：空 / 未知 / 大小写差异一律回落到 article（BR-37.4）。
func NormalizeMode(mode string) string {
	if strings.EqualFold(strings.TrimSpace(mode), ModeSnapshot) {
		return ModeSnapshot
	}
	return ModeArticle
}

// Result 是剪藏净化后的结果。
type Result struct {
	Title   string
	Content string // Markdown
	URL     string
	Mode    string

	// WebClipHTML 是 snapshot 模式下的单文件 HTML 原件（M16 / FR-83）。
	// article 模式恒为空；为空时上层降级为 Markdown + 截图。
	WebClipHTML string

	// Assets 为本地化成功、需写入附件映射的图片（FR-38 / BR-38.2）。
	Assets []MediaAsset
	// SkippedImages 为解析到但未能本地化的图片数（超限 / 下载失败 / 非 http(s)），
	// 供扩展提示「N 张图片未本地化」（BR-38.4）。
	SkippedImages int
}

var blankLinesRe = regexp.MustCompile(`\n{3,}`)

// Purify 接受原始 HTML、URL 与模式，返回净化结果（不下载媒体）。
func Purify(rawHTML, url, mode string) (*Result, error) {
	return PurifyWithOptions(rawHTML, Options{PageURL: url, Mode: mode})
}

// PurifyWithOptions 按 Options 净化；当 Options 提供了本地化依赖时一并本地化媒体。
func PurifyWithOptions(rawHTML string, opts Options) (*Result, error) {
	doc, err := html.Parse(strings.NewReader(rawHTML))
	if err != nil {
		return nil, err
	}

	mode := NormalizeMode(opts.Mode)

	// 媒体本地化先行：就地改写 <img src> 为 sui://<sha256>，失败则保留绝对 URL（BR-38.4）。
	var assets []MediaAsset
	skipped := 0
	if opts.localizeEnabled() {
		assets, skipped = localizeImages(doc, opts)
	}

	title := extractTitle(doc)

	var body *html.Node
	if mode == ModeSnapshot {
		// 整页保结构：不做主内容挑选（§4 / §4.1）
		body = findBody(doc)
	} else {
		body = findMainContent(doc)
	}

	r := &renderer{snapshot: mode == ModeSnapshot}
	// snapshot 走**保结构**的渲染路径（见 snapshot.go）：块级之间产生空行、版面信息以受限内嵌
	// HTML 块保留。article 仍走原渲染器，产物逐字节不变（FR-13 门禁）。
	var rendered string
	if r.snapshot {
		rendered = r.renderSnapshot(body)
	} else {
		rendered = r.render(body, 0)
	}
	content := strings.TrimSpace(rendered)
	// 合并多余空行
	content = blankLinesRe.ReplaceAllString(content, "\n\n")

	// M16 / FR-83：snapshot 模式额外产出单文件 HTML 原件。
	// 必须在 render 之后做（清理会删除节点，不影响已生成的 Markdown）。
	var webclip string
	if opts.CaptureHTML && mode == ModeSnapshot {
		webclip = BuildWebClipHTML(doc, opts.PageURL, opts.Client)
	}

	return &Result{
		Title:         title,
		Content:       content,
		URL:           opts.PageURL,
		Mode:          mode,
		Assets:        assets,
		SkippedImages: skipped,
		WebClipHTML:   webclip,
	}, nil
}

// extractTitle 提取页面标题：优先 <title>，其次第一个 <h1>。
func extractTitle(n *html.Node) string {
	// 找 <title>
	var findTitle func(*html.Node) string
	findTitle = func(n *html.Node) string {
		if n.Type == html.ElementNode && n.Data == "title" {
			return strings.TrimSpace(textContent(n))
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if t := findTitle(c); t != "" {
				return t
			}
		}
		return ""
	}
	if t := findTitle(n); t != "" {
		return t
	}

	// 找第一个 h1
	var findH1 func(*html.Node) string
	findH1 = func(n *html.Node) string {
		if n.Type == html.ElementNode && n.Data == "h1" {
			return strings.TrimSpace(textContent(n))
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if t := findH1(c); t != "" {
				return t
			}
		}
		return ""
	}
	return findH1(n)
}

// findMainContent 启发式找正文主容器：
// 遍历所有块级元素，计算文本密度（文本长度 / 标签数），选最大的。
func findMainContent(n *html.Node) *html.Node {
	type candidate struct {
		node  *html.Node
		score int
	}
	var best candidate

	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type != html.ElementNode {
			for c := n.FirstChild; c != nil; c = c.NextSibling {
				walk(c)
			}
			return
		}
		// 跳过噪声标签
		switch n.Data {
		case "script", "style", "nav", "footer", "header", "aside",
			"noscript", "svg", "form", "button", "input":
			return
		}
		// 对内容容器打分
		if isContentBlock(n.Data) {
			textLen := len(strings.TrimSpace(textContent(n)))
			tagCount := countElements(n)
			score := textLen - tagCount*10
			if score > best.score {
				best = candidate{n, score}
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(n)

	if best.node != nil {
		return best.node
	}
	// 兜底：返回 body
	if b := findBody(n); b != nil {
		return b
	}
	return n
}

func isContentBlock(tag string) bool {
	switch tag {
	case "article", "main", "div", "section", "body":
		return true
	}
	return false
}

func countElements(n *html.Node) int {
	count := 0
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode {
			count++
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		walk(c)
	}
	return count
}

// findBody 返回 <body>（snapshot 整页保结构用）；缺失时回退 <html>，再回退自身。
func findBody(n *html.Node) *html.Node {
	var find func(*html.Node, string) *html.Node
	find = func(n *html.Node, tag string) *html.Node {
		if n.Type == html.ElementNode && n.Data == tag {
			return n
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if f := find(c, tag); f != nil {
				return f
			}
		}
		return nil
	}
	if b := find(n, "body"); b != nil {
		return b
	}
	if h := find(n, "html"); h != nil {
		return h
	}
	return n
}

// textContent 提取节点内所有文本。
func textContent(n *html.Node) string {
	var sb strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.TextNode {
			sb.WriteString(n.Data)
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		walk(c)
	}
	return sb.String()
}

// renderer 把 HTML 子树转换为 Markdown。snapshot 决定非内容节点的剔除口径。
type renderer struct {
	snapshot bool
}

// skip 判定标签是否为非内容节点（§4.1）。
//
// 两种模式都剔除 script / style / form 等非内容节点；article 模式额外剔除
// 导航 / 页眉 / 页脚 / 侧栏（与既有 FR-13 行为一致），snapshot 则保留以维持整页结构。
func (r *renderer) skip(tag string) bool {
	switch tag {
	case "script", "style", "noscript", "svg", "iframe", "template",
		"form", "input", "button", "select", "option", "label", "textarea",
		"head", "meta", "link", "title":
		return true
	}
	if !r.snapshot {
		switch tag {
		case "nav", "header", "footer", "aside":
			return true
		}
	}
	return false
}

var spacesRe = regexp.MustCompile(`\s+`)

// render 递归转换块级结构，保持原文顺序。
func (r *renderer) render(n *html.Node, depth int) string {
	if n == nil {
		return ""
	}
	var sb strings.Builder

	for c := n.FirstChild; c != nil; c = c.NextSibling {
		switch c.Type {
		case html.TextNode:
			// 保留文本中的空白压缩
			if text := strings.TrimSpace(spacesRe.ReplaceAllString(c.Data, " ")); text != "" {
				sb.WriteString(text)
			}

		case html.ElementNode:
			if r.skip(c.Data) {
				continue
			}
			switch c.Data {
			case "h1":
				sb.WriteString("\n\n# " + inlineText(c) + "\n\n")
			case "h2":
				sb.WriteString("\n\n## " + inlineText(c) + "\n\n")
			case "h3":
				sb.WriteString("\n\n### " + inlineText(c) + "\n\n")
			case "h4":
				sb.WriteString("\n\n#### " + inlineText(c) + "\n\n")
			case "h5", "h6":
				sb.WriteString("\n\n##### " + inlineText(c) + "\n\n")
			case "p":
				if text := strings.TrimSpace(r.inline(c)); text != "" {
					sb.WriteString("\n\n" + text + "\n\n")
				}
			case "br":
				sb.WriteString("  \n")
			case "strong", "b":
				sb.WriteString("**" + r.inline(c) + "**")
			case "em", "i":
				sb.WriteString("*" + r.inline(c) + "*")
			case "del", "s", "strike":
				sb.WriteString("~~" + r.inline(c) + "~~")
			case "a":
				href := getAttr(c, "href")
				sb.WriteString("[" + r.inline(c) + "](" + EscapeMarkdownURL(href) + ")")
			case "img":
				sb.WriteString(imageMarkdown(c))
			case "picture", "figure":
				// 容器：递归保留内部 img 与图注
				sb.WriteString(r.render(c, depth+1))
			case "figcaption":
				if text := strings.TrimSpace(r.inline(c)); text != "" {
					sb.WriteString("\n\n*" + text + "*\n\n")
				}
			case "ul", "ol":
				sb.WriteString(r.list(c))
			case "table":
				if t := r.table(c); t != "" {
					sb.WriteString("\n\n" + t + "\n\n")
				}
			case "blockquote":
				text := strings.TrimSpace(r.inline(c))
				for _, line := range strings.Split(text, "\n") {
					sb.WriteString("> " + line + "\n")
				}
				sb.WriteString("\n")
			case "pre":
				sb.WriteString(r.codeBlock(c))
			case "code":
				if text := strings.TrimSpace(textContent(c)); text != "" {
					sb.WriteString("\n```\n" + text + "\n```\n\n")
				}
			case "hr":
				sb.WriteString("\n---\n\n")
			case "span", "font":
				// 行内含样式标签：直接输出内容
				sb.WriteString(r.inline(c))
			default:
				// 其他标签递归
				sb.WriteString(r.render(c, depth+1))
			}
		}
	}
	return sb.String()
}

// list 渲染 <ul> / <ol>。
func (r *renderer) list(c *html.Node) string {
	var sb strings.Builder
	sb.WriteString("\n")
	idx := 0
	for li := c.FirstChild; li != nil; li = li.NextSibling {
		if li.Type != html.ElementNode || li.Data != "li" {
			continue
		}
		text := strings.TrimSpace(r.inline(li))
		if text == "" {
			continue
		}
		idx++
		prefix := "- "
		if c.Data == "ol" {
			prefix = strconv.Itoa(idx) + ". "
		}
		sb.WriteString(prefix + text + "\n")
	}
	sb.WriteString("\n")
	return sb.String()
}

// codeBlock 渲染 <pre>：语言取自内部 <code class="language-xxx">。
func (r *renderer) codeBlock(c *html.Node) string {
	text := strings.TrimSpace(textContent(c))
	if text == "" {
		return ""
	}
	lang := ""
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if lang != "" {
			return
		}
		if n.Type == html.ElementNode && n.Data == "code" {
			for _, f := range strings.Fields(getAttr(n, "class")) {
				for _, p := range []string{"language-", "lang-"} {
					if strings.HasPrefix(f, p) {
						lang = strings.TrimPrefix(f, p)
						return
					}
				}
			}
		}
		for ch := n.FirstChild; ch != nil; ch = ch.NextSibling {
			walk(ch)
		}
	}
	walk(c)
	return "\n```" + lang + "\n" + text + "\n```\n\n"
}

// table 渲染 <table> 为 Markdown 管道表格（§4.1：快照保留表格）。
// Markdown 表格必须有表头行，因此以首行作为表头。
func (r *renderer) table(t *html.Node) string {
	var rows [][]string
	var collect func(*html.Node)
	collect = func(n *html.Node) {
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if c.Type != html.ElementNode {
				continue
			}
			switch c.Data {
			case "tr":
				var cells []string
				for cell := c.FirstChild; cell != nil; cell = cell.NextSibling {
					if cell.Type == html.ElementNode && (cell.Data == "td" || cell.Data == "th") {
						cells = append(cells, cellText(r.inline(cell)))
					}
				}
				if len(cells) > 0 {
					rows = append(rows, cells)
				}
			case "thead", "tbody", "tfoot":
				collect(c)
			}
		}
	}
	collect(t)
	if len(rows) == 0 {
		return ""
	}

	cols := 0
	for _, row := range rows {
		if len(row) > cols {
			cols = len(row)
		}
	}

	var sb strings.Builder
	sb.WriteString(tableRow(rows[0], cols))
	sb.WriteString("\n")
	sb.WriteString(tableSeparator(cols))
	sb.WriteString("\n")
	for _, row := range rows[1:] {
		sb.WriteString(tableRow(row, cols))
		sb.WriteString("\n")
	}
	return strings.TrimRight(sb.String(), "\n")
}

// cellText 规整单元格文本：换行折叠、转义管道符。
func cellText(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "|", "\\|")
	return strings.TrimSpace(s)
}

func tableRow(cells []string, cols int) string {
	var sb strings.Builder
	sb.WriteString("|")
	for i := 0; i < cols; i++ {
		cell := ""
		if i < len(cells) {
			cell = cells[i]
		}
		sb.WriteString(" " + cell + " |")
	}
	return sb.String()
}

func tableSeparator(cols int) string {
	var sb strings.Builder
	sb.WriteString("|")
	for i := 0; i < cols; i++ {
		sb.WriteString(" --- |")
	}
	return sb.String()
}

// imageMarkdown 渲染 <img>：src 可能已被媒体本地化改写为 sui://<sha256>。
// 保留 alt 与 {width/height}（BR-38.7，承 ADR-007）。
func imageMarkdown(c *html.Node) string {
	src := getAttr(c, "src")
	if src == "" {
		return ""
	}
	// M10-T30：alt 进**文本位**、src 进**目标位**，都是页面提供的字符串，必须转义
	// 结构性字符——否则一个 `]` / `)` 就能截断图片标签或目标位。
	out := "![" + EscapeMarkdownText(getAttr(c, "alt")) + "](" + EscapeMarkdownURL(src) + ")"
	if attrs := sizeAttribute(c); attrs != "" {
		out += attrs
	}
	return out
}

// sizeAttribute 依据 img 的 width/height 属性生成 {width=.. height=..}（ADR-007）。
func sizeAttribute(c *html.Node) string {
	w := normalizeSize(getAttr(c, "width"))
	h := normalizeSize(getAttr(c, "height"))
	switch {
	case w != "" && h != "":
		return "{width=" + w + " height=" + h + "}"
	case w != "":
		return "{width=" + w + "}"
	case h != "":
		return "{height=" + h + "}"
	}
	return ""
}

// normalizeSize 规整尺寸值：仅保留数字 / 小数点 / 百分号（如 "600px" → "600"，"100%" → "100%"）。
func normalizeSize(v string) string {
	var sb strings.Builder
	for _, ch := range strings.TrimSpace(v) {
		if (ch >= '0' && ch <= '9') || ch == '.' || ch == '%' {
			sb.WriteRune(ch)
		}
	}
	return sb.String()
}

// inlineText 提取纯文本（用于标题等）。
func inlineText(n *html.Node) string {
	return strings.TrimSpace(textContent(n))
}

// inline 把节点渲染为行内 Markdown。
//
// 入口先按**自身标签**判一次（inlineSelf）：这样对「行内元素本身」调用也能得到带标记的产物
// （`inline(strong)` → `**粗**`），而不是只取其文本。snapshot 侧需要逐个处理块内的行内子节点，
// 正是依赖这一点（article 侧只对「父容器」调用，行为不受影响）。
//
// 三分层刻意避免自递归：inline → inlineSelf（识别我自己）→ inlineChildren（处理我的孩子）。
// 若 inlineSelf 在未命中时回落调用 inline(n)，同一个节点会被反复识别，直接爆栈。
func (r *renderer) inline(n *html.Node) string {
	if n == nil {
		return ""
	}
	if s, ok := r.inlineSelf(n); ok {
		return s
	}
	return r.inlineChildren(n)
}

// inlineSelf 渲染单个行内元素**自身**（含其内容）；ok 为 false 表示该标签没有专属行内语法
// （容器、自定义元素等），交由调用方按「容器」递归其子节点。
func (r *renderer) inlineSelf(n *html.Node) (string, bool) {
	if n == nil || n.Type != html.ElementNode || r.skip(n.Data) {
		return "", false
	}
	inner := func() string { return r.inlineChildren(n) }
	switch n.Data {
	case "strong", "b":
		return "**" + inner() + "**", true
	case "em", "i":
		return "*" + inner() + "*", true
	case "del", "s", "strike":
		return "~~" + inner() + "~~", true
	case "a":
		return "[" + inner() + "](" + EscapeMarkdownURL(getAttr(n, "href")) + ")", true
	case "img":
		return imageMarkdown(n), true
	case "code":
		return "`" + textContent(n) + "`", true
	case "br":
		return "  \n", true
	case "sup":
		return "^" + inner(), true
	case "sub":
		return "~" + inner(), true
	}
	return "", false
}

// inlineChildren 拼接子节点的行内 Markdown：文本原样，元素先试 inlineSelf、再按容器递归。
func (r *renderer) inlineChildren(n *html.Node) string {
	var sb strings.Builder
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		switch c.Type {
		case html.TextNode:
			sb.WriteString(c.Data)
		case html.ElementNode:
			if r.skip(c.Data) {
				continue
			}
			if s, ok := r.inlineSelf(c); ok {
				sb.WriteString(s)
				continue
			}
			sb.WriteString(r.inlineChildren(c))
		}
	}
	return sb.String()
}

func getAttr(n *html.Node, key string) string {
	for _, a := range n.Attr {
		if a.Key == key {
			return a.Val
		}
	}
	return ""
}
