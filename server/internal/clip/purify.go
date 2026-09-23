// Package clip 提供网页剪藏的内容净化与 Markdown 转换。
//
// 采用轻量启发式算法：
// - 去除 script/style/nav/footer/aside 等噪声节点
// - 提取 <title> 或第一个 h1 作为标题
// - 正文：按文本密度选最大的内容块（类似 Readability 的简化版）
// - HTML → Markdown：支持标题/段落/列表/链接/粗体/斜体/图片/代码块/引用
package clip

import (
	"regexp"
	"strings"

	"golang.org/x/net/html"
)

// Result 是剪藏净化后的结果。
type Result struct {
	Title   string
	Content string // Markdown
	URL     string
}

// Purify 接受原始 HTML 和 URL，返回净化后的 Markdown 结果。
func Purify(rawHTML, url string) (*Result, error) {
	doc, err := html.Parse(strings.NewReader(rawHTML))
	if err != nil {
		return nil, err
	}

	title := extractTitle(doc)
	body := findMainContent(doc)
	content := nodeToMarkdown(body, 0)
	content = strings.TrimSpace(content)
	// 合并多余空行
	content = regexp.MustCompile(`\n{3,}`).ReplaceAllString(content, "\n\n")

	return &Result{
		Title:   title,
		Content: content,
		URL:     url,
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
	var findBody func(*html.Node) *html.Node
	findBody = func(n *html.Node) *html.Node {
		if n.Type == html.ElementNode && n.Data == "body" {
			return n
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			if b := findBody(c); b != nil {
				return b
			}
		}
		return nil
	}
	return findBody(n)
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

// nodeToMarkdown 将 HTML 子树转换为 Markdown。
func nodeToMarkdown(n *html.Node, depth int) string {
	if n == nil {
		return ""
	}
	var sb strings.Builder

	for c := n.FirstChild; c != nil; c = c.NextSibling {
		switch c.Type {
		case html.TextNode:
			text := strings.TrimSpace(c.Data)
			if text != "" {
				// 保留文本中的空白压缩
				text = regexp.MustCompile(`\s+`).ReplaceAllString(text, " ")
				sb.WriteString(text)
			}

		case html.ElementNode:
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
				text := strings.TrimSpace(inlineMarkdown(c))
				if text != "" {
					sb.WriteString("\n\n" + text + "\n\n")
				}
			case "br":
				sb.WriteString("  \n")
			case "strong", "b":
				sb.WriteString("**" + inlineMarkdown(c) + "**")
			case "em", "i":
				sb.WriteString("*" + inlineMarkdown(c) + "*")
			case "a":
				href := getAttr(c, "href")
				sb.WriteString("[" + inlineMarkdown(c) + "](" + href + ")")
			case "img":
				src := getAttr(c, "src")
				alt := getAttr(c, "alt")
				sb.WriteString("![" + alt + "](" + src + ")")
			case "ul", "ol":
				sb.WriteString("\n")
				idx := 0
				for li := c.FirstChild; li != nil; li = li.NextSibling {
					if li.Type == html.ElementNode && li.Data == "li" {
						idx++
						prefix := "- "
						if c.Data == "ol" {
							prefix = string(rune('0'+idx)) + ". "
						}
						sb.WriteString(prefix + strings.TrimSpace(inlineMarkdown(li)) + "\n")
					}
				}
				sb.WriteString("\n")
			case "blockquote":
				text := strings.TrimSpace(inlineMarkdown(c))
				lines := strings.Split(text, "\n")
				for _, line := range lines {
					sb.WriteString("> " + line + "\n")
				}
				sb.WriteString("\n")
			case "pre", "code":
				text := strings.TrimSpace(textContent(c))
				if text != "" {
					sb.WriteString("\n```\n" + text + "\n```\n\n")
				}
			case "hr":
				sb.WriteString("\n---\n\n")
			case "div", "section", "article", "main", "body":
				// 容器：递归处理子节点
				sb.WriteString(nodeToMarkdown(c, depth+1))
			case "span", "font":
				// 行内含样式标签：直接输出内容
				sb.WriteString(inlineMarkdown(c))
			case "script", "style", "nav", "footer", "header", "aside",
				"noscript", "svg", "form", "button", "input", "label", "select":
				// 跳过
			default:
				// 其他标签递归
				sb.WriteString(nodeToMarkdown(c, depth+1))
			}
		}
	}
	return sb.String()
}

// inlineText 提取纯文本（用于标题等）。
func inlineText(n *html.Node) string {
	return strings.TrimSpace(textContent(n))
}

// inlineMarkdown 处理行内元素（粗体、斜体、链接等）。
func inlineMarkdown(n *html.Node) string {
	var sb strings.Builder
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		switch c.Type {
		case html.TextNode:
			sb.WriteString(c.Data)
		case html.ElementNode:
			switch c.Data {
			case "strong", "b":
				sb.WriteString("**" + inlineMarkdown(c) + "**")
			case "em", "i":
				sb.WriteString("*" + inlineMarkdown(c) + "*")
			case "a":
				href := getAttr(c, "href")
				sb.WriteString("[" + inlineMarkdown(c) + "](" + href + ")")
			case "img":
				src := getAttr(c, "src")
				alt := getAttr(c, "alt")
				sb.WriteString("![" + alt + "](" + src + ")")
			case "code":
				sb.WriteString("`" + textContent(c) + "`")
			case "br":
				sb.WriteString("  \n")
			default:
				sb.WriteString(inlineMarkdown(c))
			}
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
