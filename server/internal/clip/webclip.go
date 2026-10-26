// M16 / FR-83：网页剪藏「单文件 HTML 原件」生成。
//
// 输入是**已经过媒体本地化**的 DOM（图片 src 已改写为 `sui://<sha256>`）。
// 本文件只做安全收口与序列化，不重复下载图片：
//   - 剔除脚本 / 事件属性 / 危险标签 / 远程样式表；
//   - 注入 CSP，禁止网络、只允许 data: 图片与内联样式；
//   - 限制总字节数，超限返回空串（上层降级为截图）。
//
// 原件是附件，不是第二正本；Markdown 仍是唯一正本（BR-23.1 / BR-83.2）。
package clip

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"golang.org/x/net/html"
)

// MaxWebClipBytes 是单篇网页原件的字节上限（12 MiB）。
const MaxWebClipBytes = 12 << 20

// 外部样式表内联限额（M16 / FR-83）：跨域 CSS 在浏览器里读不到，改由服务端拉取。
const (
	maxWebClipStyles     = 24
	maxWebClipStyleBytes = 2 << 20
	maxWebClipCSSBytes   = 4 << 20
	webClipStyleTimeout  = 10 * time.Second
)

var cssURLRe = regexp.MustCompile(`url\(\s*['"]?([^'")]+)['"]?\s*\)`)

// webClipDroppedTags 是原件中必须整块删除的标签。
//
// 与 snapshot 渲染器的 skip 口径对齐，但更严格：原件要进 WebView，故表单控件、
// 远程样式表、刷新 meta 一律不保留。
var webClipDroppedTags = map[string]bool{
	"script": true, "noscript": true, "iframe": true, "object": true, "embed": true,
	"form": true, "input": true, "button": true, "select": true, "option": true,
	"textarea": true, "link": true, "base": true, "frame": true, "frameset": true,
	"applet": true, "template": true,
}

// BuildWebClipHTML 把 DOM 序列化为单文件 HTML 原件。
//
// `pageURL` 用于解析相对样式表地址；`client` 为 nil 时使用带出网闸门的默认客户端。
// 返回空串表示不可用（超限 / 序列化失败），调用方必须降级而不是报错。
func BuildWebClipHTML(doc *html.Node, pageURL string, client *http.Client) string {
	if doc == nil {
		return ""
	}
	// 先内联外部样式表，再由 sanitize 统一剔除剩余 link（图标等）。
	inlineWebClipStyles(doc, pageURL, client)
	sanitizeWebClip(doc)
	ensureWebClipHead(doc)

	var buf bytes.Buffer
	if err := html.Render(&buf, doc); err != nil {
		return ""
	}
	if buf.Len() == 0 || buf.Len() > MaxWebClipBytes {
		return ""
	}
	return "<!DOCTYPE html>\n" + buf.String()
}

// inlineWebClipStyles 把 `<link rel=stylesheet>` 拉取为内联 `<style>`。
//
// 浏览器的 `document.styleSheets` 对跨域 CSS 会抛 SecurityError，扩展无法读取；
// 服务端有出网能力，因此在这里补齐原站主样式。任一失败都只跳过该表，不影响整篇。
func inlineWebClipStyles(doc *html.Node, pageURL string, client *http.Client) {
	base, _ := url.Parse(strings.TrimSpace(pageURL))
	var links []*html.Node
	walkNodes(doc, func(n *html.Node) {
		if n.Type == html.ElementNode && n.Data == "link" && isStyleSheetLink(n) {
			links = append(links, n)
		}
	})
	if len(links) == 0 {
		return
	}
	if client == nil {
		client = defaultMediaClient
	}
	total := 0
	for i, link := range links {
		if i >= maxWebClipStyles || total >= maxWebClipCSSBytes {
			break
		}
		href := strings.TrimSpace(attrValue(link, "href"))
		if href == "" {
			continue
		}
		ref, err := url.Parse(href)
		if err != nil {
			continue
		}
		u := ref
		if base != nil {
			u = base.ResolveReference(ref)
		}
		if u.Scheme != "http" && u.Scheme != "https" {
			continue
		}
		css, err := fetchWebClipCSS(client, u.String())
		if err != nil || css == "" {
			continue
		}
		if len(css) > maxWebClipStyleBytes || total+len(css) > maxWebClipCSSBytes {
			continue
		}
		css = rewriteCSSURLs(css, u)
		style := &html.Node{
			Type: html.ElementNode,
			Data: "style",
			Attr: []html.Attribute{{Key: "data-sui-inlined", Val: "1"}},
		}
		style.AppendChild(&html.Node{Type: html.TextNode, Data: css})
		if link.Parent != nil {
			link.Parent.InsertBefore(style, link)
			link.Parent.RemoveChild(link)
		}
		total += len(css)
	}
}

func isStyleSheetLink(n *html.Node) bool {
	rel := strings.ToLower(attrValue(n, "rel"))
	if !strings.Contains(" "+rel+" ", " stylesheet ") {
		return false
	}
	return !strings.Contains(rel, "alternate")
}

func fetchWebClipCSS(client *http.Client, href string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), webClipStyleTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, href, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", mediaUserAgent)
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", nil
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxWebClipStyleBytes+1))
	if err != nil || len(data) == 0 || len(data) > maxWebClipStyleBytes {
		return "", nil
	}
	return string(data), nil
}

// rewriteCSSURLs 把 CSS 里的相对 url(...) 解析为绝对地址（字体 / 背景图）。
func rewriteCSSURLs(css string, base *url.URL) string {
	return cssURLRe.ReplaceAllStringFunc(css, func(raw string) string {
		m := cssURLRe.FindStringSubmatch(raw)
		if len(m) < 2 {
			return raw
		}
		v := strings.TrimSpace(m[1])
		if v == "" || strings.HasPrefix(v, "data:") || strings.HasPrefix(v, "http:") ||
			strings.HasPrefix(v, "https:") || strings.HasPrefix(v, "//") ||
			strings.HasPrefix(v, "#") || strings.HasPrefix(v, "about:") {
			return raw
		}
		ref, err := url.Parse(v)
		if err != nil {
			return raw
		}
		abs := base.ResolveReference(ref).String()
		abs = strings.ReplaceAll(abs, `"`, "%22")
		return `url("` + abs + `")`
	})
}

// sanitizeWebClip 递归删除危险节点与属性。
func sanitizeWebClip(n *html.Node) {
	for c := n.FirstChild; c != nil; {
		next := c.NextSibling
		if c.Type == html.ElementNode {
			tag := strings.ToLower(c.Data)
			if webClipDroppedTags[tag] {
				n.RemoveChild(c)
				c = next
				continue
			}
			if tag == "meta" && strings.EqualFold(attrValue(c, "http-equiv"), "refresh") {
				n.RemoveChild(c)
				c = next
				continue
			}
			c.Attr = safeWebClipAttrs(c.Attr)
		}
		sanitizeWebClip(c)
		c = next
	}
}

// safeWebClipAttrs 删除事件属性 / 危险 URL 属性；其余属性原样保留（含 style / class）。
func safeWebClipAttrs(attrs []html.Attribute) []html.Attribute {
	out := attrs[:0]
	for _, a := range attrs {
		key := strings.ToLower(a.Key)
		if strings.HasPrefix(key, "on") || key == "srcdoc" || key == "formaction" {
			continue
		}
		if key == "href" || key == "src" || key == "xlink:href" || key == "action" {
			if dangerousWebClipURL(a.Val) {
				continue
			}
		}
		out = append(out, a)
	}
	return out
}

// dangerousWebClipURL 判断 URL 是否必须丢弃。
//
// 只拦脚本类协议；http(s) 外链保留为普通链接，WebView 侧会拦截导航。
func dangerousWebClipURL(raw string) bool {
	v := strings.ToLower(strings.TrimSpace(raw))
	return strings.HasPrefix(v, "javascript:") ||
		strings.HasPrefix(v, "vbscript:") ||
		strings.HasPrefix(v, "data:text/html")
}

// ensureWebClipHead 确保 head / charset / CSP 存在。
func ensureWebClipHead(doc *html.Node) {
	head := findFirstElement(doc, "head")
	if head == nil {
		htmlNode := findFirstElement(doc, "html")
		if htmlNode == nil {
			return
		}
		head = &html.Node{Type: html.ElementNode, Data: "head"}
		htmlNode.InsertBefore(head, htmlNode.FirstChild)
	}
	// 已有 charset / CSP 先移除，避免重复或旧值覆盖。
	for c := head.FirstChild; c != nil; {
		next := c.NextSibling
		if c.Type == html.ElementNode && c.Data == "meta" {
			if attrValue(c, "charset") != "" ||
				strings.EqualFold(attrValue(c, "http-equiv"), "Content-Security-Policy") {
				head.RemoveChild(c)
			}
		}
		c = next
	}
	appendMeta(head, []html.Attribute{{Key: "charset", Val: "utf-8"}})
	appendMeta(head, []html.Attribute{
		{Key: "http-equiv", Val: "Content-Security-Policy"},
		{Key: "content", Val: "default-src 'none'; img-src data: sui:; style-src 'unsafe-inline'; font-src data:"},
	})
	appendMeta(head, []html.Attribute{
		{Key: "name", Val: "sui-snapshot"},
		{Key: "content", Val: "v1"},
	})
}

func appendMeta(head *html.Node, attrs []html.Attribute) {
	head.AppendChild(&html.Node{Type: html.ElementNode, Data: "meta", Attr: attrs})
}

func findFirstElement(n *html.Node, tag string) *html.Node {
	if n.Type == html.ElementNode && strings.EqualFold(n.Data, tag) {
		return n
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if found := findFirstElement(c, tag); found != nil {
			return found
		}
	}
	return nil
}

func attrValue(n *html.Node, key string) string {
	for _, a := range n.Attr {
		if strings.EqualFold(a.Key, key) {
			return a.Val
		}
	}
	return ""
}
