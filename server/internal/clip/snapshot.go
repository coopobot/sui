package clip

// M6 / FR-37 全页快照（snapshot）的**块级结构保留**与**受限内嵌 HTML**（承 ADR-010）。
//
// 背景（实测）：整页快照沿用 article 的渲染器时，`div` / `section` 等容器走「递归 + 节点间不写分隔」，
// `<div>行1</div><div>行2</div>` 会被拼成「行1行2」，整页塌成一大段——版式信息（居中、颜色、
// 字号、缩进）也全部丢失。本文件只服务 snapshot：article 的产物必须逐字节不变（FR-13 门禁）。
//
// 两条正交的处理：
//   - **块级结构**：相邻块级元素之间一律以空行分隔（CommonMark 的段落语义），同一容器内的行内
//     内容仍保持同行（行内元素绝不被拆成独立块）；
//   - **受限内嵌 HTML**：当「段落级」块的后代全是行内元素、且带版式信息（白名单内的内联 style /
//     align 属性 / `<center>` 标签）时，整块输出为**裸 HTML 块**（前后各一个空行，符合 CommonMark
//     的 HTML block 语义）。没有版式信息则仍走原 Markdown 路径——标题 / 列表 / 表格 / 引用 /
//     代码块 / 图片尺寸等既有能力一项不丢。
//
// 安全口径（与 BR-23.1「正本即 Markdown」不冲突：产物仍是 Markdown，HTML 只是其中的受限子集）：
//   - `style` 只放行白名单属性，值一律**归一化为小写、单 token（不含空格）**，不合法即**丢弃**
//     （绝不原样透传页面字符串）；
//   - `class` / `id` / `on*` 事件属性 / `style` 之外的内联属性一律不进产物；
//   - `script` / `style` / `iframe` 等非内容节点沿用 `renderer.skip` 的既有剔除口径（整块丢弃）。

import (
	"strconv"
	"strings"

	"golang.org/x/net/html"
)

// blockTagSet 是「块级」标签：它们在页面上各自占据一个块，渲染时**必须**与相邻块之间产生空行。
//
// 口径刻意保守：只列常见块级标签。**不在**此集合的标签按「容器 / 行内」分别处理——自定义元素与
// 未知标签按容器递归（拆成内部块），已知行内标签（见 inlineTagSet）始终留在行内。
var blockTagSet = map[string]bool{
	"address": true, "article": true, "aside": true, "blockquote": true, "body": true,
	"center": true, "dd": true, "details": true, "dialog": true, "dir": true, "div": true,
	"dl": true, "dt": true, "fieldset": true, "figcaption": true, "figure": true,
	"footer": true, "form": true, "h1": true, "h2": true, "h3": true, "h4": true,
	"h5": true, "h6": true, "header": true, "hgroup": true, "hr": true, "html": true,
	"legend": true, "li": true, "main": true, "menu": true, "nav": true, "ol": true,
	"p": true, "pre": true, "section": true, "summary": true, "table": true, "tbody": true,
	"td": true, "tfoot": true, "th": true, "thead": true, "tr": true, "ul": true,
}

// inlineTagSet 是**内嵌 HTML 块**里允许出现的行内元素（白名单，BR-37.2 的受限子集）。
//
// 白名单外的元素不会原样透传：`renderer.skip` 命中的内容节点整块剔除，其余元素只保留其文本 /
// 行内子节点（相当于丢掉那层包装），因此 `<object>` / `<embed>` 之类不可能进产物。
var inlineTagSet = map[string]bool{
	"b": true, "strong": true, "i": true, "em": true, "u": true, "s": true,
	"del": true, "code": true, "span": true, "sub": true, "sup": true, "mark": true,
	"a": true, "img": true, "br": true, "font": true,
}

// emitTagSet 是允许被「整块输出为裸 HTML 块」的**段落级**标签：
// 它们承载一段行内内容，而 Markdown 无法表达其版式。
//
// 标题 / 列表 / 表格 / 引用 / 代码块等**不在此列**——它们的 Markdown 表达力足够，
// 一旦被包进 HTML 块反而丢掉既有能力（规则 4）。
var emitTagSet = map[string]bool{
	"div": true, "p": true, "center": true, "span": true, "section": true,
	"article": true, "figure": true, "figcaption": true, "font": true,
}

// blockProps 是「当前块上下文继承下来的行内样式」。
//
// 用途只有一个：容器自身带对齐（`text-align` / `align` / `<center>`）而子元素是块级时，
// 把对齐**下推**给内部「段落级」子孙块，让居中等效果仍然可见（规则 5）。
type blockProps struct {
	// style 为继承下来的行内样式（已归一化，形如 `text-align:center`）；空串表示无。
	style string
	// align 为继承下来的对齐取值（left / center / right / justify）；空串表示无。
	align string
}

// sanitizeInlineText 规整块内文本：折叠空白（HTML 语义下换行等价于空格），再按 HTML 转义。
//
// 折叠而**不** TrimSpace：行内元素之间的空格是有意义的（`<b>a</b> <i>b</i>`）；
// 整块两端的空白由片段合并统一裁剪。
func sanitizeInlineText(s string) string {
	return html.EscapeString(spacesRe.ReplaceAllString(s, " "))
}

// stripBlankLines 折叠连续换行：行内位置（列表项 / 表格单元格 / HTML 块内）一旦出现空行，
// 就会把 Markdown 结构拆坏（列表截断、表格断行），故行内内容里的空行一律压成单个换行。
func stripBlankLines(s string) string {
	return blankLinesRe.ReplaceAllString(s, "\n")
}

// normalizeInlineText 规整**行内位置**的文本节点：把换行 / 制表符折叠成空格，但**保留**首尾空格。
//
// 保留原因：行内元素之间的空格是有意义的（`正文 <strong>粗</strong> 尾` 里的两个空格来自相邻
// 文本节点，丢掉就得到「正文**粗**尾」）。绝不能在这里 TrimSpace——那是把「行内拼接」的口径
// 混同于「块级裁剪」，正是整页塌成一行的成因之一。
//
// 纯空白文本（如块级标签之间的换行）会被原样折叠成单个空格；`finish` 丢弃纯空白片段，
// 因此它不会在产出里留下空段。
func normalizeInlineText(s string) string {
	return spacesRe.ReplaceAllString(s, " ")
}

// isBlockElement 报告节点是否按块级处理。
//
// 行内标签**永不**按块级处理：`<p>正文 <span style="color:red">红</span></p>` 里的 span 一旦被
// 当成块，整段行内文字就会被拆成好几个段落（实测过这个塌法），故此处显式排除 inlineTagSet。
func isBlockElement(n *html.Node) bool {
	if n == nil || n.Type != html.ElementNode {
		return false
	}
	if inlineTagSet[n.Data] {
		return false
	}
	return blockTagSet[n.Data] || emitTagSet[n.Data]
}

// hasBlockDescendant 报告元素内是否存在**块级**节点。
//
// 已剔除的节点（script / style 等）内部即使含块级标签也不算——它们整块不出现在产物里。
func hasBlockDescendant(n *html.Node) bool {
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type != html.ElementNode || skipContentTag(c.Data) {
			continue
		}
		if isBlockElement(c) || hasBlockDescendant(c) {
			return true
		}
	}
	return false
}

// skipContentTag 报告标签是否属于「非内容节点」（两种模式都整块剔除）。
//
// 与 renderer.skip 的公共部分一致；此处独立成小函数，只为结构判定用，避免为一次判定去构造 renderer。
func skipContentTag(tag string) bool {
	switch tag {
	case "script", "style", "noscript", "svg", "iframe", "object", "embed", "template",
		"form", "input", "button", "select", "option", "label", "textarea",
		"head", "meta", "link", "title":
		return true
	}
	return false
}

// hasInlineHTMLContent 报告块内是否还有行内内容需要保留（文本或行内元素）。
//
// 已剔除的节点不算：`<div><style>…</style></div>` 在该口径下是**空块**，不该为它留下空壳。
func hasInlineHTMLContent(n *html.Node) bool {
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		switch c.Type {
		case html.TextNode:
			if strings.TrimSpace(c.Data) != "" {
				return true
			}
		case html.ElementNode:
			if skipContentTag(c.Data) {
				continue
			}
			return true
		}
	}
	return false
}

// hasStyledInlineElement 报告块内是否存在**带版式**的行内元素（白名单 style 或 align 属性）。
//
// 判断只看能否解析出可用型号：`<span class="x">` 之类没有版式信息，不必为它改走 HTML 块。
func hasStyledInlineElement(n *html.Node) bool {
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if c.Type != html.ElementNode || skipContentTag(c.Data) {
			continue
		}
		if inlineTagSet[c.Data] {
			if parseStyleWhitelist(getAttr(c, "style")) != "" || strings.TrimSpace(getAttr(c, "align")) != "" {
				return true
			}
		}
		if hasStyledInlineElement(c) {
			return true
		}
	}
	return false
}

// snapshotHTMLBlock 渲染 `<div [style="..."]>行内HTML</div>`：snapshot 里表达版式的**唯一**形态。
//
// 统一用 `div` 而不是保留原标签：`<center>`（已废弃）与 `align` 属性都归一到 `text-align`，
// 语义一致、写法唯一，客户端只需认这一种形态。
func snapshotHTMLBlock(style, inner string) string {
	if strings.TrimSpace(inner) == "" {
		return ""
	}
	open := "<div>"
	if style != "" {
		open = `<div style="` + style + `">`
	}
	return open + inner + "</div>"
}

// pushdownProps 计算要下推给子孙块的样式：块自身的样式优先，缺项时补上继承下来的对齐。
//
// 「已在父块生效的 text-align 不重复下发」——否则多层嵌套会给同一段落叠加同一对齐声明。
func pushdownProps(n *html.Node, inherited blockProps) blockProps {
	style := parseStyleWhitelist(getAttr(n, "style"))
	align := textAlignOf(style)
	if style == "" {
		style = inherited.style
		align = inherited.align
	}
	if align == "" && n.Data == "center" {
		align = "center"
	}
	if align == "" {
		align = normalizeTextAlign(strings.ToLower(strings.TrimSpace(getAttr(n, "align"))))
	}
	if align != "" && textAlignOf(style) == "" {
		style = joinStyle(style, "text-align:"+align)
	}
	return blockProps{style: style, align: align}
}

// renderSnapshot 转换**根节点**的子节点（snapshot 模式下即 `<body>`）。
//
// 根节点自身的版式（如 `<body style="text-align:center">`）也要下推给子孙块，否则整页居中会丢。
func (r *renderer) renderSnapshot(root *html.Node) string {
	st := &snapshotState{}
	if root != nil {
		r.fillSnapshot(st, root, pushdownProps(root, blockProps{}))
	}
	return st.finish()
}

// snapshotState 累积快照渲染的片段。
//
// 片段列表最终以**空行**相连（`finish`），因此片段边界就是段落边界；「同一段行内内容」必须
// 累积成**同一个**片段，否则一段行内文字会被相邻的行内元素切成多个段落（实测过的塌法）。
//
// 状态只有一位：`pendingInline` = 最后一个片段是否还能继续吸收行内内容。规则：
//   - 行内片段可以继续吸收（相邻行内元素与文本保持同行）；
//   - 块级片段不能吸收：紧随其后的行内文本必须**另起片段**，否则「块 + 行内」又被拼成一行。
type snapshotState struct {
	frags         []string
	pendingInline bool
}

func (st *snapshotState) appendInlineText(s string) {
	if s == "" {
		return
	}
	if st.pendingInline && len(st.frags) > 0 {
		st.frags[len(st.frags)-1] += s
		return
	}
	st.frags = append(st.frags, s)
	st.pendingInline = true
}

func (st *snapshotState) appendBlockFragment(s string) {
	if strings.TrimSpace(s) == "" {
		return
	}
	st.frags = append(st.frags, strings.TrimSpace(s))
	st.pendingInline = false
}

// finish 合并片段：以空行相连，并清掉空片段。
//
// 空片段（如纯空白文本节点产生）在此被丢弃，因此它不会在产出里留下空段。
func (st *snapshotState) finish() string {
	kept := make([]string, 0, len(st.frags))
	for _, f := range st.frags {
		if strings.TrimSpace(f) != "" {
			kept = append(kept, strings.TrimSpace(f))
		}
	}
	return strings.Join(kept, "\n\n")
}

// fillSnapshot 遍历 container 的子节点，按块级 / 行内分流。
//
// 关键口径：只有**块级**子节点会产生片段分隔；行内子节点与相邻文本始终同行。
func (r *renderer) fillSnapshot(st *snapshotState, container *html.Node, inherited blockProps) {
	for c := container.FirstChild; c != nil; c = c.NextSibling {
		switch c.Type {
		case html.TextNode:
			// 保留文本中的空白压缩；节点之间不写分隔（行内内容同行）
			st.appendInlineText(normalizeInlineText(c.Data))
		case html.ElementNode:
			if r.skip(c.Data) {
				continue
			}
			if !isBlockElement(c) {
				// 行内元素：与相邻文本同行（不产生段落分隔）。
				// 注意：这里的行内元素处在**块级位置**（如 `<div>` 直接含 `<img>`），
				// 其版式无处安放，按既有 Markdown 路径输出，与 article 口径一致。
				st.appendInlineText(stripBlankLines(r.inline(c)))
				continue
			}
			if frag := r.renderBlock(c, inherited); frag != "" {
				st.appendBlockFragment(frag)
			}
		}
	}
}

// renderBlock 处理一个块级节点：先按「Markdown 能力 / 容器 / 版式块」分流，必要时下推对齐（规则 5）。
func (r *renderer) renderBlock(c *html.Node, inherited blockProps) string {
	return r.renderMarkdownBlock(c, inherited)
}

// renderMarkdownBlock 处理不在 HTML 块内的块级节点。
func (r *renderer) renderMarkdownBlock(c *html.Node, inherited blockProps) string {
	switch c.Data {
	case "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "table", "hr":
		// Markdown 表达力足够（标题 / 列表 / 表格 / 分隔线）：原样复用既有渲染器（规则 4）。
		return r.renderOnce(c)
	case "blockquote":
		return r.snapshotBlockquote(c)
	case "pre":
		return r.snapshotCodeBlock(c)
	case "li", "td", "th":
		// 列表项 / 表格单元格：内容按行内渲染，空行会截断列表与表格，故折叠掉。
		return stripBlankLines(r.renderOnce(c))
	}

	// 生效样式 = 自身样式，缺项时补上继承下来的对齐（规则 5 下推的落点就在这里）。
	layout := parseStyleWhitelist(getAttr(c, "style"))
	align := textAlignOf(layout)
	if align == "" && c.Data == "center" {
		// `<center>` 是已废弃但仍在用的对齐标签：内联样式取不到时补上 text-align:center。
		align = "center"
	}
	if align == "" {
		align = normalizeTextAlign(strings.ToLower(strings.TrimSpace(getAttr(c, "align"))))
	}
	if layout == "" {
		layout = inherited.style
	}
	if align != "" && textAlignOf(layout) == "" {
		layout = joinStyle(layout, "text-align:"+align)
	}
	hasLayout := layout != ""
	hasBlock := hasBlockDescendant(c)
	// 块自身没有版式、但内部有**带版式的行内元素**（如 `<span style="color:red">`）时，
	// 也必须走 HTML 块：否则这层行内版式会被 Markdown 路径丢掉（内容不丢，但颜色 / 字号丢）。
	forcedByInline := layout == "" && hasStyledInlineElement(c)

	// 规则 3：段落级块 + 后代全是行内元素 + 带版式信息 → 整块输出为受限 HTML 块。
	//
	// `hasBlock` 为真时**不能**整块 HTML 化：那会把内部的标题 / 列表 / 表格变成纯 HTML 文本，
	// 丢掉 Markdown 表达力（规则 4），故此处改为下推对齐。
	if emitTagSet[c.Data] && (hasLayout || forcedByInline) && !hasBlock && hasInlineHTMLContent(c) {
		if inner := r.inlineHTMLContent(c); inner != "" {
			return snapshotHTMLBlock(layout, inner)
		}
	}

	// 规则 5：容器自身带对齐（或只是把对齐继承下去）但内部确有块级子孙 → 把版式**下推**给子孙块，
	// 让它们各自单独成 HTML 块。
	if (hasLayout || inherited.style != "") && hasBlock {
		return r.renderChildren(c, pushdownProps(c, inherited))
	}

	// 规则 4：无版式信息（或带版式但内含块级子孙且无法下推）→ 既有 Markdown 路径。
	return r.renderMarkdownFallback(c, inherited)
}

// renderMarkdownFallback 把块交回既有 Markdown 渲染器，只在必要时自建「块分隔」。
//
// 分流依据是「这个标签是否有既有的 Markdown 语义」：
//   - `div` / `section` / `article` 等**透明容器**：既有渲染器对它走 default 递归且节点间不写
//     分隔（「行1行2」的根因），故改由 renderChildren 逐子渲染并补空行；
//   - 其余标签（`figure` / `figcaption` / `center` 等）走既有渲染器——`<figure>` 的图注斜体等
//     既有能力由它自己保证，自建渲染反而会丢。
//
// 继承样式（来自对齐下推）在这里不再额外处理：只剩「无块级子孙」的块会走到这里，
// 而它们已在上一步按行内内容处理成 HTML 块。
func (r *renderer) renderMarkdownFallback(c *html.Node, inherited blockProps) string {
	switch c.Data {
	case "div", "section", "article", "main", "aside", "header", "footer", "nav", "body", "html", "form", "fieldset", "details", "dialog", "dir", "menu", "dd":
		return r.renderChildren(c, inherited)
	}
	return r.renderOnce(c)
}

// renderChildren 处理容器的子节点：块级子孙走 renderBlock 并**彼此以空行分隔**；
// 行内子孙与相邻文本同行。
//
// 不能直接复用既有 renderer.render：那里对 `div` 等标签走 default 递归且节点间不写分隔，
// 正是「行1行2」的根因。
func (r *renderer) renderChildren(c *html.Node, inherited blockProps) string {
	sub := &snapshotState{}
	for ch := c.FirstChild; ch != nil; ch = ch.NextSibling {
		switch ch.Type {
		case html.TextNode:
			sub.appendInlineText(normalizeInlineText(ch.Data))
		case html.ElementNode:
			if r.skip(ch.Data) {
				continue
			}
			if isBlockElement(ch) {
				if frag := r.renderBlock(ch, inherited); frag != "" {
					sub.appendBlockFragment(frag)
				}
				continue
			}
			sub.appendInlineText(stripBlankLines(r.inline(ch)))
		}
	}
	return sub.finish()
}

// renderOnce 复用既有 Markdown 渲染器处理**单个**块级元素。
//
// 既有 renderer.render 是「把 n 的所有子节点渲染成 Markdown」，对块级元素恰好等于渲染它本身
// （见其 heading / p / ul / table / pre / hr 等分支）。为免复制一份能力表，这里把元素临时挂到
// 一个包装节点下交给它，并**临时截断兄弟链**——否则渲染会顺着 NextSibling 一路走下去，
// 把同一层剩下的兄弟重复渲一遍（实测过的坑：整段内容出现两份）。
func (r *renderer) renderOnce(c *html.Node) string {
	// 引用与代码块走 snapshot 自己的实现：既有分支会把引用折叠成一行、把代码块首尾空白裁掉。
	if c.Type == html.ElementNode {
		switch c.Data {
		case "blockquote":
			return r.snapshotBlockquote(c)
		case "pre":
			return r.snapshotCodeBlock(c)
		}
	}
	wrapper := &html.Node{Type: html.ElementNode, Data: "div"}
	next := c.NextSibling
	c.NextSibling = nil
	defer func() { c.NextSibling = next }()
	wrapper.FirstChild = c
	wrapper.LastChild = c
	return r.render(wrapper, 0)
}

// snapshotBlockquote 渲染引用：逐行加 `> ` 前缀，并保留页面的换行意图。
//
// 既有 renderer 的引用分支走 textContent（`<br>` 会被抹掉、换行被折叠成一行），
// 那是 article 的既定产物（FR-13 门禁，不能动）；snapshot 侧另写一份：
// `<br>` 与文本换行都成为引用内的换行，行内标记（粗体 / 链接）照旧保留。
func (r *renderer) snapshotBlockquote(c *html.Node) string {
	lines := r.quoteLines(c)
	if len(lines) == 0 {
		return ""
	}
	var sb strings.Builder
	for _, line := range lines {
		sb.WriteString("> " + line + "\n")
	}
	return strings.TrimRight(sb.String(), "\n")
}

// quoteLines 取引用的行内内容并按行规整：行首尾空白（含源码缩进）裁掉，空行丢弃。
//
// 源码缩进是**排版噪声**（HTML 里换行 + 空格在渲染时等价于一个空格），若原样带入
// `> 引用行一 ` 这类行尾括号反而显得脏；而 `<br>` 与文本换行是页面**有意的**换行，必须保住。
func (r *renderer) quoteLines(c *html.Node) []string {
	var lines []string
	for _, raw := range strings.Split(r.quoteInline(c), "\n") {
		if line := strings.TrimSpace(raw); line != "" {
			lines = append(lines, line)
		}
	}
	return lines
}

// quoteInline 渲染引用内的行内内容，并把 `<br>` 归一为换行（行内路径会把它渲成 Markdown 硬换行）。
func (r *renderer) quoteInline(c *html.Node) string {
	var sb strings.Builder
	for ch := c.FirstChild; ch != nil; ch = ch.NextSibling {
		switch ch.Type {
		case html.TextNode:
			sb.WriteString(quoteText(ch.Data))
		case html.ElementNode:
			if r.skip(ch.Data) {
				continue
			}
			switch {
			case ch.Data == "br":
				sb.WriteString("\n")
			case ch.Data == "blockquote":
				// 嵌套引用：内层自带 `> ` 前缀，这里**直接并入**（不插空行，否则 `> > 内层`
				// 会被空行拆成两段引用）。
				sb.WriteString(r.snapshotBlockquote(ch))
			case isBlockElement(ch):
				// 引用内的其他块：取其行内内容，块之间以换行分隔（保持可读，不引入 Markdown 结构）。
				if sb.Len() > 0 {
					sb.WriteString("\n")
				}
				sb.WriteString(r.inlineContentPlain(ch))
			default:
				sb.WriteString(r.inline(ch))
			}
		}
	}
	return sb.String()
}

// quoteText 规整引用内的文本节点：**逐行**折叠空白，并保留行结构。
//
// 不能先把换行换成空格再整体折叠——那会把「引用行一\n引用行二」压成一行，正是既有实现丢掉
// 页面换行的原因。HTML 里的换行在**行内**位置等价于空格，但在引用这类**块内块**位置是版式信息。
func quoteText(s string) string {
	raw := strings.Split(s, "\n")
	lines := make([]string, 0, len(raw))
	for _, line := range raw {
		lines = append(lines, strings.TrimSpace(spacesRe.ReplaceAllString(line, " ")))
	}
	return strings.Join(lines, "\n")
}

// inlineContentPlain 把块的子节点渲染为行内内容（块级子节点递归、并用换行分隔）。
func (r *renderer) inlineContentPlain(c *html.Node) string {
	var sb strings.Builder
	for ch := c.FirstChild; ch != nil; ch = ch.NextSibling {
		switch ch.Type {
		case html.TextNode:
			sb.WriteString(quoteText(ch.Data))
		case html.ElementNode:
			if r.skip(ch.Data) {
				continue
			}
			if !isBlockElement(ch) {
				sb.WriteString(r.inline(ch))
				continue
			}
			sb.WriteString(r.inlineContentPlain(ch))
			sb.WriteString("\n")
		}
	}
	return sb.String()
}

// snapshotCodeBlock 渲染 `<pre>`：语言取自内部 `<code class="language-xxx">`，
// 正文取**原始文本**（既有 codeBlock 会 TrimSpace 掉首尾空白，代码块的首行缩进是内容，必须保住）。
func (r *renderer) snapshotCodeBlock(c *html.Node) string {
	text := strings.Trim(textContent(c), "\r\n")
	if strings.TrimSpace(text) == "" {
		return ""
	}
	lang := ""
	walkNodes(c, func(n *html.Node) {
		if lang != "" || n.Type != html.ElementNode || n.Data != "code" {
			return
		}
		for _, f := range strings.Fields(getAttr(n, "class")) {
			for _, p := range []string{"language-", "lang-"} {
				if strings.HasPrefix(f, p) {
					lang = strings.TrimPrefix(f, p)
					return
				}
			}
		}
	})
	return "\n```" + lang + "\n" + text + "\n```\n\n"
}

// ---- 受限内联 HTML 序列化 ----

// inlineHTMLContent 把块内的行内子树序列化为**受限** HTML（返回空串表示无内容）。
func (r *renderer) inlineHTMLContent(n *html.Node) string {
	var sb strings.Builder
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		sb.WriteString(r.inlineHTMLNode(c))
	}
	return sb.String()
}

// inlineHTMLNode 序列化单个节点；返回空串表示该节点不进产物。
//
// 白名单外的元素（`<picture>` / `<label>` / 自定义元素等）只递归取其子内容——等于丢掉那层包装，
// 而不会把未受控的标签名带进产物（`<object>` / `<embed>` 之类已由 skip 整块剔除）。
func (r *renderer) inlineHTMLNode(n *html.Node) string {
	switch n.Type {
	case html.TextNode:
		if strings.TrimSpace(n.Data) == "" {
			return ""
		}
		return sanitizeInlineText(n.Data)
	case html.ElementNode:
		if r.skip(n.Data) {
			return ""
		}
		if !inlineTagSet[n.Data] {
			return r.inlineHTMLContent(n)
		}
		if n.Data == "img" {
			return inlineImgTag(n)
		}
		if n.Data == "br" {
			return "<br>"
		}
		var sb strings.Builder
		sb.WriteString("<" + n.Data + inlineAttrs(n.Data, n) + ">")
		sb.WriteString(r.inlineHTMLContent(n))
		sb.WriteString("</" + n.Data + ">")
		return sb.String()
	}
	return ""
}

// inlineAttrs 只输出白名单属性：`class` / `id` / `on*` 事件属性与其余属性一律丢弃。
func inlineAttrs(tag string, n *html.Node) string {
	var sb strings.Builder
	switch tag {
	case "span", "font":
		// 行内元素自身也能带版式：同样过白名单，绝不透传原始 style 字符串。
		if style := parseStyleWhitelist(getAttr(n, "style")); style != "" {
			sb.WriteString(` style="` + style + `"`)
		}
	}
	if tag == "a" {
		if href := strings.TrimSpace(getAttr(n, "href")); isSafeInlineURL(href) {
			sb.WriteString(` href="` + html.EscapeString(href) + `"`)
		}
	}
	if tag == "font" {
		if color, ok := normalizeStyleColor(strings.ToLower(strings.TrimSpace(getAttr(n, "color")))); ok {
			sb.WriteString(` color="` + color + `"`)
		}
	}
	return sb.String()
}

// isSafeInlineURL 拒绝可执行协议：`style` 已白名单化，`href` 也必须同等受限。
//
// 注意 `sui://<sha256>`（媒体本地化后的地址）必须放行——它是本项目的应用内地址方案。
func isSafeInlineURL(raw string) bool {
	if raw == "" {
		return false
	}
	lower := strings.ToLower(raw)
	for _, bad := range []string{"javascript:", "vbscript:", "data:"} {
		if strings.HasPrefix(lower, bad) {
			return false
		}
	}
	return true
}

// inlineImgTag 渲染 HTML 块里的图片：`<img src="..." width="600" height="400" alt="...">`。
//
// `src` 已被上游 localizeImages 改写为 `sui://<sha256>`（未成功时是绝对外链）；
// 尺寸取 width / height 属性或内联样式的**像素**值，缺省不写（规则 6）。
func inlineImgTag(n *html.Node) string {
	src := strings.TrimSpace(getAttr(n, "src"))
	if src == "" {
		// 无来源的图片不进产物：空 `<img>` 只会渲染成破图。
		return ""
	}
	var sb strings.Builder
	sb.WriteString(`<img src="` + html.EscapeString(src) + `"`)
	if w := imgSize(n, "width"); w != "" {
		sb.WriteString(` width="` + w + `"`)
	}
	if h := imgSize(n, "height"); h != "" {
		sb.WriteString(` height="` + h + `"`)
	}
	sb.WriteString(` alt="` + html.EscapeString(getAttr(n, "alt")) + `">`)
	return sb.String()
}

// imgSize 取图片尺寸：优先内联样式的像素值，其次 width / height 属性。
func imgSize(n *html.Node, prop string) string {
	if v := imgStyleSize(getAttr(n, "style"), prop); v != "" {
		return v
	}
	return normalizeSize(getAttr(n, prop))
}

// imgStyleSize 从内联样式里取 `width:600px` / `height:400px` 的像素值（非 px 无法在属性位表达）。
func imgStyleSize(style, prop string) string {
	for _, decl := range splitDeclarations(style) {
		i := strings.IndexByte(decl, ':')
		if i < 0 || strings.ToLower(strings.TrimSpace(decl[:i])) != prop {
			continue
		}
		v := strings.ToLower(strings.TrimSpace(decl[i+1:]))
		if !strings.HasSuffix(v, "px") {
			continue
		}
		if size := normalizeSize(v); size != "" {
			return size
		}
	}
	return ""
}

// ---- 内联样式白名单 ----

// styleRules 是内联样式白名单：属性 → 取值校验。
//
// 校验一律**整体**判定（值必须是「小写单 token」）：这样既不可能出现 `expression(...)` 之类
// 可执行构造，也不可能借空格 / 引号逃逸出声明位。不合法的值**丢弃**，绝不原样透传。
var styleRules = map[string]func(string) (string, bool){
	"text-align":       normalizeStyleAlign,
	"color":            normalizeStyleColor,
	"background-color": normalizeStyleColor,
	"font-weight":      normalizeStyleFontWeight,
	"font-style":       normalizeStyleFontStyle,
	"text-decoration":  normalizeStyleTextDecoration,
	"font-size":        normalizeStyleFontSize,
	"text-indent":      normalizeStyleTextIndent,
}

// parseStyleWhitelist 解析内联样式，返回**归一化**后的白名单声明（形如 `text-align:center;color:#f00`）。
//
// 同属性只取第一条（后者被忽略）：避免页面用重复声明绕开校验口径。
func parseStyleWhitelist(style string) string {
	var out []string
	seen := make(map[string]bool)
	for _, decl := range splitDeclarations(style) {
		i := strings.IndexByte(decl, ':')
		if i < 0 {
			continue
		}
		prop := strings.ToLower(strings.TrimSpace(decl[:i]))
		rule, ok := styleRules[prop]
		if !ok || seen[prop] {
			continue
		}
		value, valid := rule(strings.ToLower(strings.TrimSpace(decl[i+1:])))
		if !valid {
			continue
		}
		seen[prop] = true
		out = append(out, prop+":"+value)
	}
	return strings.Join(out, ";")
}

// textAlignOf 取样式串里的 text-align 值（无则空串）。
func textAlignOf(style string) string {
	for _, decl := range strings.Split(style, ";") {
		if v, ok := strings.CutPrefix(decl, "text-align:"); ok {
			return v
		}
	}
	return ""
}

// joinStyle 追加一条声明；已有同名属性时原样返回（先到先得，与 parseStyleWhitelist 一致）。
func joinStyle(style, decl string) string {
	prop := decl
	if i := strings.IndexByte(decl, ':'); i >= 0 {
		prop = decl[:i]
	}
	for _, cur := range strings.Split(style, ";") {
		if strings.HasPrefix(cur, prop+":") {
			return style
		}
	}
	if style == "" {
		return decl
	}
	return style + ";" + decl
}

// splitDeclarations 按 `;` 切分声明。
//
// 刻意不做 CSS 注释 / 转义的完整解析：值一律白名单化，注释或转义只会让整条声明被丢弃，
// 这正是想要的结果（不合法即丢，而不是猜测页面意图）。
func splitDeclarations(style string) []string {
	if strings.TrimSpace(style) == "" {
		return nil
	}
	return strings.Split(style, ";")
}

// singleTokenValue 判定「小写单 token」：只含小写字母 / 数字 / `#` / `%` / `.` / `-`，且无空白。
//
// 白名单属性的合法取值全部落在这个字符集内，故该判定足够且最保守。
func singleTokenValue(v string) bool {
	if v == "" {
		return false
	}
	for i := 0; i < len(v); i++ {
		switch ch := v[i]; {
		case ch >= 'a' && ch <= 'z':
		case ch >= '0' && ch <= '9':
		case ch == '#' || ch == '%' || ch == '.' || ch == '-':
		default:
			return false
		}
	}
	return true
}

func normalizeStyleAlign(v string) (string, bool) {
	switch v {
	case "left", "center", "right", "justify":
		return v, true
	}
	return "", false
}

// normalizeTextAlign 把 `align` 属性的取值映射到 text-align（`middle` 是历史别名）。
func normalizeTextAlign(v string) string {
	if v == "middle" {
		v = "center"
	}
	switch v {
	case "left", "center", "right", "justify":
		return v
	}
	return ""
}

// normalizeStyleColor 只接受 `#rgb` / `#rrggbb` / 纯字母色名（如 `red` / `rebeccapurple`）。
func normalizeStyleColor(v string) (string, bool) {
	if v == "" || !singleTokenValue(v) {
		return "", false
	}
	if v[0] == '#' {
		hex := v[1:]
		if len(hex) != 3 && len(hex) != 6 {
			return "", false
		}
		for i := 0; i < len(hex); i++ {
			if !isHexDigit(hex[i]) {
				return "", false
			}
		}
		return v, true
	}
	for i := 0; i < len(v); i++ {
		if v[i] < 'a' || v[i] > 'z' {
			return "", false
		}
	}
	return v, true
}

func isHexDigit(c byte) bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
}

func normalizeStyleFontWeight(v string) (string, bool) {
	if v == "bold" || v == "normal" {
		return v, true
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 100 || n > 900 {
		return "", false
	}
	return strconv.Itoa(n), true
}

func normalizeStyleFontStyle(v string) (string, bool) {
	if v == "italic" || v == "normal" {
		return v, true
	}
	return "", false
}

func normalizeStyleTextDecoration(v string) (string, bool) {
	switch v {
	case "underline", "line-through", "none":
		return v, true
	}
	return "", false
}

// normalizeStyleFontSize 只接受 `NNpx` / `NN%`，且像素值须落在 8..72（合理的正文字号区间）。
func normalizeStyleFontSize(v string) (string, bool) {
	return normalizeSizeWithUnit(v, 8, 72, true)
}

// normalizeStyleTextIndent 只接受 `NNpx` / `NN%`；缩进可以很大，故不做上限。
func normalizeStyleTextIndent(v string) (string, bool) {
	return normalizeSizeWithUnit(v, 0, 0, false)
}

// normalizeSizeWithUnit 校验 `NNpx` / `NN%`；`boundPx` 为真时对像素值做区间校验。
func normalizeSizeWithUnit(v string, min, max int, boundPx bool) (string, bool) {
	var num, unit string
	switch {
	case strings.HasSuffix(v, "px"):
		num, unit = strings.TrimSuffix(v, "px"), "px"
	case strings.HasSuffix(v, "%"):
		num, unit = strings.TrimSuffix(v, "%"), "%"
	default:
		return "", false
	}
	n, err := strconv.Atoi(num)
	if err != nil || n < 0 {
		return "", false
	}
	if boundPx && unit == "px" && (n < min || n > max) {
		return "", false
	}
	return strconv.Itoa(n) + unit, true
}
