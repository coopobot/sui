package clip

// M6 / FR-37 全页快照（snapshot）的**块级结构保留**与**受限内嵌 HTML**门禁。
//
// 这些用例锁的是 ADR-010 的补充口径（见 snapshot.go 头部说明）：
//   - 相邻块级元素之间必须有空行，绝不能拼成「行1行2」；
//   - 版式信息（对齐 / 颜色 / 字号 / 缩进）以受限 HTML 块保留；
//   - 无版式信息时仍走既有 Markdown 路径（标题 / 列表 / 表格 / 引用 / 代码块 / 图片尺寸一项不丢）；
//   - article 模式产物**逐字节不变**（FR-13 向后兼容门禁）。

import (
	"strings"
	"testing"
)

// snapshotContent 以 snapshot 模式净化 HTML 并返回正文（无媒体本地化）。
func snapshotContent(t *testing.T, html string) string {
	t.Helper()
	res, err := Purify(html, "https://page.example/p", ModeSnapshot)
	if err != nil {
		t.Fatalf("Purify(snapshot) 失败：%v", err)
	}
	return res.Content
}

// articleContent 以 article 模式净化 HTML 并返回正文。
func articleContent(t *testing.T, html string) string {
	t.Helper()
	res, err := Purify(html, "https://page.example/p", ModeArticle)
	if err != nil {
		t.Fatalf("Purify(article) 失败：%v", err)
	}
	return res.Content
}

// TestSnapshotBlockSeparation：相邻块级元素之间必须产生**空行**（规则 1 / 2）。
// 修复前 `<div>行1</div><div>行2</div>` 被拼成「行1行2」，整页塌成一段。
func TestSnapshotBlockSeparation(t *testing.T) {
	got := snapshotContent(t, `<html><body><div>行1</div><div>行2</div></body></html>`)
	if strings.Contains(got, "行1行2") {
		t.Fatalf("相邻块级元素不得被拼接；实际：%q", got)
	}
	if got != "行1\n\n行2" {
		t.Fatalf("相邻块级元素之间应有一个空行；实际：%q", got)
	}
}

// TestSnapshotBlockSeparationThreeLevels：三层嵌套容器里的同级块同样逐块分隔（规则 2）。
func TestSnapshotBlockSeparationThreeLevels(t *testing.T) {
	got := snapshotContent(t, `<html><body><div><div><div>甲</div><div>乙</div></div><div>丙</div></div></body></html>`)
	const want = "甲\n\n乙\n\n丙"
	if got != want {
		t.Fatalf("嵌套容器内的块应逐块分隔；实际：%q，期望：%q", got, want)
	}
}

// TestSnapshotArticleModeUnchanged：同一输入在 article 下仍是旧口径（规则 1 门禁）。
//
// article 的既定行为就是「块间无分隔的文字流」，这里显式断言它**没有**跟着 snapshot 一起变。
// 注意把两个 div 放进同正文容器内：article 会先做正文挑选（同级散落的 div 只会被选中一个），
// 这不是本用例要考察的口径。
func TestSnapshotArticleModeUnchanged(t *testing.T) {
	const page = `<html><body><article>` +
		`<p>这是足够长的正文段落内容，用于提升文本密度以命中正文容器。</p>` +
		`<div>行1</div><div>行2</div>` +
		`</article></body></html>`

	article := articleContent(t, page)
	if strings.Contains(article, "行1\n") {
		t.Fatalf("article 模式不得引入块分隔（产物必须逐字节不变）；实际：%q", article)
	}
	if !strings.Contains(article, "行1行2") {
		t.Fatalf("article 模式对同一 div 序列应保持旧口径（拼接）；实际：%q", article)
	}

	// 同一输入在 snapshot 下必须已分隔——两者口径不同，不能互相污染。
	if snap := snapshotContent(t, page); strings.Contains(snap, "行1行2") {
		t.Fatalf("snapshot 必须分隔相邻块；实际：%q", snap)
	}
}

// TestSnapshotHTMLBlockNeedsLayout：无版式信息的普通段落仍走 Markdown（规则 4 / 6）。
func TestSnapshotHTMLBlockNeedsLayout(t *testing.T) {
	got := snapshotContent(t, `<html><body><p>普通段落一</p><p>普通段落二</p></body></html>`)
	const want = "普通段落一\n\n普通段落二"
	if got != want {
		t.Fatalf("无版式信息的段落应走 Markdown；实际：%q，期望：%q", got, want)
	}
	// 只有版式信息才产生 HTML 块：无 style / align / center 时不得出现任何标签。
	if strings.Contains(got, "<div") {
		t.Fatalf("无版式信息不得包 HTML；实际：%q", got)
	}
}

// TestSnapshotCenterBlockKeepsLayout：居中块 + 图片 → 受限 HTML 块（规则 3 / 6）。
//
// `src` 已在净化上游被 localizeImages 改写（可能是 `sui://<sha256>`，也可能是降级后的外链），
// 渲染只做转义与尺寸落位，不改变来源。
func TestSnapshotCenterBlockKeepsLayout(t *testing.T) {
	got := snapshotContent(t,
		`<html><body><div style="text-align:center"><img src="https://img.example/a.png" width="600" height="400" alt="图"></div></body></html>`)

	if !strings.Contains(got, `<div style="text-align:center">`) {
		t.Fatalf("居中块应输出受限 HTML 块；实际：%q", got)
	}
	if !strings.Contains(got, `<img src="https://img.example/a.png" width="600" height="400" alt="图">`) {
		t.Fatalf("图片应保留 src / 尺寸 / alt；实际：%q", got)
	}
	if !strings.Contains(got, "</div>") {
		t.Fatalf("HTML 块应闭合；实际：%q", got)
	}

	// 尺寸也可来自内联样式的像素值（规则 6）。
	styled := snapshotContent(t,
		`<html><body><div align="center"><img src="sui://abc" style="width:320px;height:240px"></div></body></html>`)
	if !strings.Contains(styled, `<div style="text-align:center">`) {
		t.Fatalf("align=center 应归一到 text-align:center；实际：%q", styled)
	}
	if !strings.Contains(styled, `width="320"`) || !strings.Contains(styled, `height="240"`) {
		t.Fatalf("图片尺寸应取自内联样式的像素值；实际：%q", styled)
	}

	// 媒体本地化后的 `sui://<sha256>` 地址必须原样保留、不被当外链丢掉。
	localized := snapshotContent(t,
		`<html><body><div style="text-align:center"><img src="sui://0123456789abcdef"></div></body></html>`)
	if !strings.Contains(localized, `src="sui://0123456789abcdef"`) {
		t.Fatalf("本地化地址应原样保留；实际：%q", localized)
	}
}

// TestSnapshotAlignPushdownToChildBlocks：容器带对齐但子元素是块级 → 对齐下推（规则 5）。
func TestSnapshotAlignPushdownToChildBlocks(t *testing.T) {
	got := snapshotContent(t,
		`<html><body><div style="text-align:center"><p>x</p><p>y</p></div></body></html>`)
	if got != "<div style=\"text-align:center\">x</div>\n\n<div style=\"text-align:center\">y</div>" {
		t.Fatalf("两个段落应各自处于居中的 HTML 块内；实际：%q", got)
	}

	// 深层下推：容器 → 中间容器 → 段落，对齐仍要落到位。
	deep := snapshotContent(t,
		`<html><body><center><div><div><p>深</p></div></div></center></body></html>`)
	if !strings.Contains(deep, `<div style="text-align:center">深</div>`) {
		t.Fatalf("对齐应下推到深层块；实际：%q", deep)
	}
}

// TestSnapshotHTMLBlockInjectionGuard：注入用例（规则 3 的安全口径）。
func TestSnapshotHTMLBlockInjectionGuard(t *testing.T) {
	got := snapshotContent(t, `<html><body>`+
		`<div style="color:red" onclick="alert(1)" class="x" id="y">t</div>`+
		`<script>var track=true;</script>`+
		`</body></html>`)

	if !strings.Contains(got, `<div style="color:red">t</div>`) {
		t.Fatalf("白名单内联样式应保留；实际：%q", got)
	}
	for _, banned := range []string{"onclick", "class=", "id=", "alert(1)", "var track"} {
		if strings.Contains(got, banned) {
			t.Fatalf("产物不得包含 %q；实际：%q", banned, got)
		}
	}
}

// TestSnapshotStyleWhitelistDropsIllegalValues：非法样式值一律**丢弃**（不原样透传）。
func TestSnapshotStyleWhitelistDropsIllegalValues(t *testing.T) {
	cases := []struct {
		name  string
		style string
		want  string
	}{
		{"rgb 函数", "background-color: rgb(1,2,3)", ""},
		{"expression", "color: expression(alert(1))", ""},
		{"含空格的字体名", `font-family: "A B"`, ""},
		{"属性不在白名单", "position:fixed", ""},
		{"字号越界", "font-size:200px", ""},
		{"字号非法单位", "font-size:2em", ""},
		{"合法多属性", "text-align:center;color:#f00;font-size:14px", "text-align:center;color:#f00;font-size:14px"},
		{"取值归一化为小写", "COLOR:RED;TEXT-ALIGN:CENTER", "color:red;text-align:center"},
		{"非法 # 长度", "color:#ff00", ""},
		{"合法色名与缩进", "color:rebeccapurple;text-indent:24px", "color:rebeccapurple;text-indent:24px"},
		{"重复属性取首条", "color:red;color:blue", "color:red"},
		{"合法与非法混排", "color:blue;background-color:rgb(1,2,3)", "color:blue"},
	}
	for _, tc := range cases {
		if got := parseStyleWhitelist(tc.style); got != tc.want {
			t.Errorf("%s：parseStyleWhitelist(%q) = %q，期望 %q", tc.name, tc.style, got, tc.want)
		}
	}

	// 端到端：非法值不得把标签带进产物，也不得产出空 style 属性。
	got := snapshotContent(t, `<html><body><div style="background-color:rgb(1,2,3)">甲</div>`+
		`<div style="color:blue;font-family:&quot;A B&quot;">乙</div>`+
		`<div style="width:100px" align="x">丙</div></body></html>`)
	if strings.Contains(got, "style=") && !strings.Contains(got, `<div style="color:blue">乙</div>`) {
		t.Fatalf("只应保留合法声明；实际：%q", got)
	}
	if strings.Contains(got, "rgb(") || strings.Contains(got, "100px") {
		t.Fatalf("非法样式值不得出现在产物里；实际：%q", got)
	}
	if !strings.Contains(got, `<div style="color:blue">乙</div>`) {
		t.Fatalf("合法声明应构成 HTML 块；实际：%q", got)
	}
	// 「甲」「丙」没有任何合法版式信息 → 回到 Markdown，不加 HTML 包裹。
	for _, raw := range []string{"甲", "丙"} {
		if !strings.Contains(got, raw) {
			t.Fatalf("内容不得丢失：%q；实际：%q", raw, got)
		}
	}
	if strings.Contains(got, "<div>甲</div>") || strings.Contains(got, "<div>丙</div>") {
		t.Fatalf("无版式信息不得包 HTML 块；实际：%q", got)
	}
}

// TestSnapshotDropsNonContentNodes：非内容节点整块剔除，正文块仍保留（规则 3）。
func TestSnapshotDropsNonContentNodes(t *testing.T) {
	got := snapshotContent(t, `<html><body>`+
		`<div style="color:red">保留我</div>`+
		`<script>var a=1;</script><style>.x{color:red}</style>`+
		`<iframe src="https://evil.example/"></iframe>`+
		`<object data="x"></object><embed src="y"><svg><text>矢量</text></svg>`+
		`<div>普通块</div></body></html>`)

	for _, banned := range []string{"var a=1", ".x{", "evil.example", "矢量"} {
		if strings.Contains(got, banned) {
			t.Fatalf("非内容节点不得进入产物：%q；实际：%q", banned, got)
		}
	}
	for _, want := range []string{"保留我", "普通块"} {
		if !strings.Contains(got, want) {
			t.Fatalf("正文不得被误删：%q；实际：%q", want, got)
		}
	}
}

// TestSnapshotKeepsMarkdownCapabilities：无版式信息时既有 Markdown 能力一项不丢（规则 4 / 6）。
func TestSnapshotKeepsMarkdownCapabilities(t *testing.T) {
	const page = `<html><body><article>` +
		`<h2>小标题</h2>` +
		`<p>正文里 <strong>粗</strong>、<em>斜</em>、<a href="https://a.example/x?a=1)2">链接</a>、` +
		`<code>码</code>、<del>删</del>、<sub>下</sub>、<sup>上</sup>。</p>` +
		`<ul><li>项目一</li><li>项目二</li></ul>` +
		`<table><thead><tr><th>列A</th><th>列B</th></tr></thead><tbody><tr><td>单元1</td><td>单元2</td></tr></tbody></table>` +
		`<blockquote>引用行一
引用行二</blockquote>` +
		`<pre><code class="language-go">func main() {}</code></pre>` +
		`<figure><img src="https://img.example/c.png" width="600"><figcaption>图注文字</figcaption></figure>` +
		`<hr><p>收尾段落</p>` +
		`</article></body></html>`

	article := articleContent(t, page)
	snapshot := snapshotContent(t, page)

	for _, want := range []string{
		"## 小标题", "**粗**", "*斜*", "[链接](https://a.example/x?a=1\\)2)", "`码`", "~~删~~",
		"项目一", "| 列A | 列B |", "单元1", "引用行一", "```go", "func main() {}", "图注文字", "---",
		"**粗**",
	} {
		if !strings.Contains(snapshot, want) {
			t.Errorf("snapshot 丢了既有 Markdown 能力 %q；实际：\n%s", want, snapshot)
		}
	}
	// 图片的 Markdown 形态（含 `{width=N}`）在无版式块里保持不变（规则 6）。
	if !strings.Contains(snapshot, "![](https://img.example/c.png){width=600}") {
		t.Errorf("Markdown 路径的图片应保留 {width=N}；实际：\n%s", snapshot)
	}
	// 引用保留页面换行（既有 article 口径会把两行折成一行，snapshot 侧不跟随）。
	if !strings.Contains(snapshot, "> 引用行一\n> 引用行二") {
		t.Errorf("引用应保留页面换行；实际：\n%s", snapshot)
	}
	// 纯文本段落不得被 HTML 包裹。
	if strings.Contains(snapshot, "<div") {
		t.Errorf("无版式信息时不得出现 HTML 块；实际：\n%s", snapshot)
	}
	// 标题 / 图注等既有语义不变。
	if !strings.Contains(article, "*图注文字*") {
		t.Errorf("article 的图注口径不应被改动；实际：\n%s", article)
	}
}

// TestSnapshotAlignAttributeAndCenterTag：`align` 属性与 `<center>` 标签都归一到 text-align（规则 3）。
func TestSnapshotAlignAttributeAndCenterTag(t *testing.T) {
	got := snapshotContent(t, `<html><body>`+
		`<div align="right">靠右</div>`+
		`<center>居中老标签</center>`+
		`<div align="middle">中间</div>`+
		`<div align="x">非法对齐</div>`+
		`</body></html>`)

	for _, want := range []string{
		`<div style="text-align:right">靠右</div>`,
		`<div style="text-align:center">居中老标签</div>`,
		`<div style="text-align:center">中间</div>`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("缺少 %q；实际：\n%s", want, got)
		}
	}
	// 非法 align 取值不构成版式信息 → 回到 Markdown，且不得把 align 原样带出。
	if strings.Contains(got, "align=") {
		t.Errorf("产物不得保留 align 属性；实际：\n%s", got)
	}
	if !strings.Contains(got, "非法对齐") {
		t.Errorf("内容不得丢失；实际：\n%s", got)
	}
}

// TestSnapshotInlineHTMLBlockWhitelist：HTML 块内的行内白名单与属性白名单（规则 3）。
func TestSnapshotInlineHTMLBlockWhitelist(t *testing.T) {
	got := snapshotContent(t, `<html><body>`+
		`<div style="color:#f00">前<b>粗</b><span style="color:red" class="x" id="y" onclick="e()">红</span>`+
		`<a href="https://a.example/p" onclick="e()">链</a><a href="javascript:alert(1)">坏链</a>`+
		`<font color="blue" size="7" face="A">字</font><mark>标</mark><sub>下</sub><sup>上</sup>`+
		`<unknown class="c">裸</unknown></div>`+
		`</body></html>`)

	for _, want := range []string{
		`<b>粗</b>`,
		`<span style="color:red">红</span>`,
		`<a href="https://a.example/p">链</a>`,
		`<font color="blue">字</font>`,
		`<mark>标</mark>`,
		`<sub>下</sub>`,
		`<sup>上</sup>`,
		`裸`,
	} {
		if !strings.Contains(got, want) {
			t.Errorf("HTML 块内应保留 %q；实际：\n%s", want, got)
		}
	}
	for _, banned := range []string{"class=", "id=", "onclick", "javascript:", `size="7"`, `face="A"`} {
		if strings.Contains(got, banned) {
			t.Errorf("HTML 块内不得出现 %q；实际：\n%s", banned, got)
		}
	}
}

// TestSnapshotHTMLEmphasisWithMarkdownInside：块内出现 Markdown 结构时不得被 HTML 化（规则 4）。
//
// 带 style 的容器若含标题 / 列表 / 表格，整块 HTML 化会把这些结构变成纯文本；
// 此时改为下推对齐、保留 Markdown。
func TestSnapshotHTMLEmphasisWithMarkdownInside(t *testing.T) {
	got := snapshotContent(t, `<html><body>`+
		`<div style="text-align:center"><h3>标题</h3><ul><li>项目</li></ul></div>`+
		`</body></html>`)

	if strings.Contains(got, "<h3") || strings.Contains(got, "<li") {
		t.Fatalf("Markdown 结构不得被 HTML 化；实际：\n%s", got)
	}
	if !strings.Contains(got, "### 标题") {
		t.Fatalf("标题应保留 Markdown 形态；实际：\n%s", got)
	}
	if !strings.Contains(got, "- 项目") {
		t.Fatalf("列表应保留 Markdown 形态；实际：\n%s", got)
	}
}

// TestSnapshotStyledInlineInsidePlainBlock：块自身无样式、但内部有带版式的行内元素时，
// 也必须改走 HTML 块——否则这层行内版式会被 Markdown 路径丢掉（规则 3）。
func TestSnapshotStyledInlineInsidePlainBlock(t *testing.T) {
	got := snapshotContent(t,
		`<html><body><p>前<span style="color:red">红字</span>后</p><p>纯<span>无样式</span>文本</p></body></html>`)

	if !strings.Contains(got, `<div>前<span style="color:red">红字</span>后</div>`) {
		t.Fatalf("带版式的行内元素所在块应输出 HTML 块；实际：%q", got)
	}
	// 没有版式的行内元素不构成理由，仍走 Markdown（不得凭空加 HTML 包裹）。
	if !strings.Contains(got, "纯无样式文本") {
		t.Fatalf("无版式内容的块应走 Markdown；实际：%q", got)
	}
	if strings.Contains(got, "<div>纯") {
		t.Fatalf("无版式的块不得被 HTML 化；实际：%q", got)
	}
}

// TestSnapshotHTMLBlockIsOwnLine：HTML 块必须独占一行（前后各一个空行）。
func TestSnapshotHTMLBlockIsOwnLine(t *testing.T) {
	got := snapshotContent(t, `<html><body>`+
		`<p>前一段</p><div style="color:red">版式块</div><p>后一段</p>`+
		`</body></html>`)
	const want = "前一段\n\n<div style=\"color:red\">版式块</div>\n\n后一段"
	if got != want {
		t.Fatalf("HTML 块应独占一行且前后留空行；实际：%q，期望：%q", got, want)
	}
}
