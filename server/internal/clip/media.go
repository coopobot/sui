package clip

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/html"

	"sui/note-server/internal/blob"
)

// 媒体本地化默认限额（BR-38.5）。具体阈值以本节常量为准，并已回填
// clip-engine.md §4.2。
const (
	// DefaultMaxImageBytes 单图字节上限（10 MiB）；超限按降级处理。
	DefaultMaxImageBytes int64 = 10 << 20
	// DefaultMaxImages 单篇剪藏最多本地化的图片数；超出部分按降级处理。
	DefaultMaxImages = 200
	// DefaultTotalTimeout 全部图片本地化的总时长上限。
	DefaultTotalTimeout = 30 * time.Second
	// defaultImageTimeout 单张图片下载的超时上限。
	defaultImageTimeout = 10 * time.Second
)

// mediaUserAgent 是服务端出网下载图片时声明的 UA（部分站点据此返回原图）。
// 括号注释位按爬虫惯例标注项目公开地址（形如 Googlebot/2.1 (+http://...)）：
// 便于被访问站点识别来源、倾向放行而非拦截；删除它功能上仍可运行，但会失去这一层可识别性。
// 不要伪装成浏览器 UA——部分 CDN 会据此返回压缩/缩略图，反而拿不到原图。
const mediaUserAgent = "SuiClip/0.7 (+https://coopobot.github.io/sui/)"

// Options 控制剪藏净化与媒体本地化行为（M6 / FR-37 / FR-38）。
type Options struct {
	// PageURL 页面 URL：既用于解析相对图片地址，也用于幂等键与来源标注。
	PageURL string
	// Mode 剪藏模式（article | snapshot）；空 / 未知回落 article（BR-37.4）。
	Mode string

	// Blobs 附件字节存储（内容寻址）。为 nil 时不做媒体本地化，图片保留外链。
	Blobs blob.Store
	// Client 下载图片使用的 HTTP 客户端；为 nil 时使用共享的默认客户端。
	Client *http.Client

	// MaxImageBytes 单图字节上限；<=0 时取 DefaultMaxImageBytes。
	MaxImageBytes int64
	// MaxImages 单篇最多本地化的图片数；<=0 时取 DefaultMaxImages。
	MaxImages int
	// TotalTimeout 媒体本地化总时长上限；<=0 时取 DefaultTotalTimeout。
	TotalTimeout time.Duration
}

// localizeEnabled 报告是否具备本地化所需的依赖（存储 + 页面 URL）。
func (o Options) localizeEnabled() bool {
	return o.Blobs != nil && strings.TrimSpace(o.PageURL) != ""
}

func (o Options) maxImageBytes() int64 {
	if o.MaxImageBytes > 0 {
		return o.MaxImageBytes
	}
	return DefaultMaxImageBytes
}

func (o Options) maxImages() int {
	if o.MaxImages > 0 {
		return o.MaxImages
	}
	return DefaultMaxImages
}

func (o Options) totalTimeout() time.Duration {
	if o.TotalTimeout > 0 {
		return o.TotalTimeout
	}
	return DefaultTotalTimeout
}

// MediaAsset 是一张本地化成功的图片，供上层写入附件映射（FR-38 / BR-38.2）。
//
// SHA256 即内容地址：既是附件对应的 blob 键，也是正文 `sui://<sha256>` 引用。
type MediaAsset struct {
	// SHA256 内容摘要（小写十六进制）。
	SHA256 string
	// Filename 展示名（取自 URL 末段，必要时按内容类型补扩展名）。
	Filename string
	// MimeKind 附件大类；图片恒为 "image"（供客户端选图标）。
	MimeKind string
	// ByteSize 字节数。
	ByteSize int
	// SourceURL 原始（已解析为绝对的）地址，仅用于日志 / 调试。
	SourceURL string
}

// defaultMediaClient 是共享的默认下载客户端（复用连接池）。
var defaultMediaClient = &http.Client{Timeout: defaultImageTimeout}

// localizeImages 遍历 doc 中全部 <img>，就地改写可下载图片的 src 为
// `sui://<sha256>`，并把字节写入内容寻址存储（FR-38）。
//
// 返回成功本地化的资产列表（按 sha256 去重）与「未本地化」图片计数
// （超限 / 下载失败 / 非 http(s) 协议，BR-38.4）；任何单图失败都不阻断整篇。
func localizeImages(doc *html.Node, opts Options) ([]MediaAsset, int) {
	var imgs []*html.Node
	walkNodes(doc, func(n *html.Node) {
		if n.Type == html.ElementNode && n.Data == "img" {
			imgs = append(imgs, n)
		}
	})
	if len(imgs) == 0 {
		return nil, 0
	}

	client := opts.Client
	if client == nil {
		client = defaultMediaClient
	}
	maxBytes := opts.maxImageBytes()
	maxImages := opts.maxImages()
	deadline := time.Now().Add(opts.totalTimeout())

	assets := make([]MediaAsset, 0, len(imgs))
	byHash := make(map[string]MediaAsset, len(imgs))
	skipped := 0
	processed := 0

	for _, img := range imgs {
		raw, ok := resolveImageSource(img, opts.PageURL)
		if !ok {
			// 无任何可用来源：无可下载对象，不计入「未本地化」。
			continue
		}
		if processed >= maxImages || !time.Now().Before(deadline) {
			// 超限降级：保留（已解析的）绝对 URL，不阻断整篇（BR-38.4 / BR-38.5）。
			skipped++
			degrade(img, raw)
			continue
		}
		processed++

		asset, err := fetchAndStore(client, opts.Blobs, raw, maxBytes, deadline)
		if err != nil {
			// 单图失败降级：保留（已解析的）绝对 URL，不阻断整篇（BR-38.4）。
			skipped++
			degrade(img, raw)
			continue
		}

		if prev, dup := byHash[asset.SHA256]; dup {
			// 同一张图多次引用：只登记一份资产（内容寻址天然去重）。
			asset = prev
		} else {
			byHash[asset.SHA256] = asset
			assets = append(assets, asset)
		}

		// 正文引用改写为应用内地址（BR-38.2），后续渲染为 ![alt](sui://<sha256>)。
		setAttr(img, "src", "sui://"+asset.SHA256)
	}

	return assets, skipped
}

// degrade 把无法本地化的 <img> 降级为「保留绝对 URL」（BR-38.4）：
// 就地写回 src，使后续渲染产出的是绝对外链而非原始相对地址。
func degrade(img *html.Node, resolvedURL string) {
	if resolvedURL == "" {
		return
	}
	setAttr(img, "src", resolvedURL)
}

// resolveImageSource 依 BR-38.1 解析 <img> 的来源并解析为绝对 URL。
//
// 优先级：src → data-src / data-original / data-lazy-src → srcset 最大项。
// 第二个返回值报告是否存在可用候选（区别于候选为空与候选不可用）。
func resolveImageSource(img *html.Node, pageURL string) (string, bool) {
	for _, key := range []string{"src", "data-src", "data-original", "data-lazy-src"} {
		if v := strings.TrimSpace(getAttr(img, key)); v != "" {
			return resolveURL(v, pageURL), true
		}
	}
	if v := largestFromSrcset(getAttr(img, "srcset")); v != "" {
		return resolveURL(v, pageURL), true
	}
	return "", false
}

// resolveURL 把候选地址解析为绝对 URL：相对地址按页面 URL 解析（BR-38.1）。
func resolveURL(raw, pageURL string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	// 协议相对写法（//host/path）：补上页面协议。
	if strings.HasPrefix(raw, "//") {
		if base, err := url.Parse(pageURL); err == nil && base.Scheme != "" {
			raw = base.Scheme + ":" + raw
		}
	}
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	if u.IsAbs() {
		return u.String()
	}
	base, err := url.Parse(pageURL)
	if err != nil {
		return raw
	}
	return base.ResolveReference(u).String()
}

// largestFromSrcset 从 srcset 中挑选描述符最大的一项（BR-38.1 兜底）。
func largestFromSrcset(srcset string) string {
	best := ""
	bestScore := -1.0
	for _, part := range strings.Split(srcset, ",") {
		fields := strings.Fields(strings.TrimSpace(part))
		if len(fields) == 0 {
			continue
		}
		score := 1.0
		if len(fields) > 1 {
			switch d := strings.ToLower(fields[1]); {
			case strings.HasSuffix(d, "w"):
				if v, err := strconv.ParseFloat(strings.TrimSuffix(d, "w"), 64); err == nil {
					score = v
				}
			case strings.HasSuffix(d, "x"):
				if v, err := strconv.ParseFloat(strings.TrimSuffix(d, "x"), 64); err == nil {
					score = v * 1000 // 像素密度描述符（2x）与宽度描述符量纲对齐
				}
			}
		}
		if score > bestScore {
			bestScore = score
			best = fields[0]
		}
	}
	return best
}

// fetchAndStore 下载单张图片 → sha256 → blob.Put（内容寻址，幂等去重）。
// 仅接受 http / https；超时 / 非 200 / 超限 / 空体均按失败返回（BR-38.4 / BR-38.5）。
func fetchAndStore(
	client *http.Client, blobs blob.Store, rawURL string, maxBytes int64, deadline time.Time,
) (MediaAsset, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return MediaAsset{}, fmt.Errorf("clip: 解析图片地址失败: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return MediaAsset{}, fmt.Errorf("clip: 不支持的协议 %q", u.Scheme)
	}

	timeout := defaultImageTimeout
	if remaining := time.Until(deadline); remaining < timeout {
		timeout = remaining
	}
	if timeout <= 0 {
		return MediaAsset{}, fmt.Errorf("clip: 媒体本地化已超时")
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return MediaAsset{}, err
	}
	req.Header.Set("User-Agent", mediaUserAgent)
	req.Header.Set("Accept", "image/*,*/*;q=0.8")

	resp, err := client.Do(req)
	if err != nil {
		return MediaAsset{}, fmt.Errorf("clip: 下载 %s 失败: %w", u.Redacted(), err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return MediaAsset{}, fmt.Errorf("clip: 下载 %s 返回 %s", u.Redacted(), resp.Status)
	}

	// 多读一字节以判定是否超过上限。
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return MediaAsset{}, fmt.Errorf("clip: 读取 %s 失败: %w", u.Redacted(), err)
	}
	if int64(len(data)) > maxBytes {
		return MediaAsset{}, fmt.Errorf("clip: %s 超过单图上限 %d 字节", u.Redacted(), maxBytes)
	}
	if len(data) == 0 {
		return MediaAsset{}, fmt.Errorf("clip: %s 内容为空", u.Redacted())
	}

	sum := sha256.Sum256(data)
	hash := hex.EncodeToString(sum[:])
	// 已有同 hash 时 Put 直接返回 0（内容寻址天然去重）。
	if _, err := blobs.Put(hash, bytes.NewReader(data)); err != nil {
		return MediaAsset{}, fmt.Errorf("clip: 写入附件失败: %w", err)
	}

	return MediaAsset{
		SHA256:    hash,
		Filename:  imageFilename(u, resp.Header.Get("Content-Type")),
		MimeKind:  "image",
		ByteSize:  len(data),
		SourceURL: u.String(),
	}, nil
}

// imageFilename 推断图片展示名：优先 URL 末段，缺失时按内容类型补扩展名。
func imageFilename(u *url.URL, contentType string) string {
	base := path.Base(u.Path)
	if base == "." || base == "/" {
		base = ""
	}
	if base != "" {
		if path.Ext(base) != "" {
			return base
		}
		if ext := imageExt(contentType); ext != "" {
			return base + ext
		}
		return base
	}
	if ext := imageExt(contentType); ext != "" {
		return "image" + ext
	}
	return "image"
}

// imageExt 由 Content-Type 推断图片扩展名（未知返回空串）。
func imageExt(contentType string) string {
	ct := strings.ToLower(strings.TrimSpace(contentType))
	if i := strings.IndexByte(ct, ';'); i >= 0 {
		ct = strings.TrimSpace(ct[:i])
	}
	switch ct {
	case "image/jpeg", "image/jpg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "image/svg+xml":
		return ".svg"
	case "image/bmp":
		return ".bmp"
	case "image/avif":
		return ".avif"
	case "image/heic", "image/heif":
		return ".heic"
	case "image/tiff":
		return ".tiff"
	case "image/x-icon", "image/vnd.microsoft.icon":
		return ".ico"
	}
	return ""
}

// walkNodes 深度优先遍历节点树。
func walkNodes(n *html.Node, fn func(*html.Node)) {
	if n == nil {
		return
	}
	fn(n)
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		walkNodes(c, fn)
	}
}

// setAttr 就地设置（或追加）节点属性。
func setAttr(n *html.Node, key, val string) {
	for i := range n.Attr {
		if n.Attr[i].Key == key {
			n.Attr[i].Val = val
			return
		}
	}
	n.Attr = append(n.Attr, html.Attribute{Key: key, Val: val})
}
