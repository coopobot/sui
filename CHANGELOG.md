# 变更日志

本文件记录随手记 Sui 的重要变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.8.3] - 2026-10-04

M7 补丁：移动端（窄屏）版本历史入口修复。

### 修复

- **移动端点「版本历史」无反应（B19）** — 窄屏（`maxWidth < 900`，含 Android / iOS 手机）
  骨架为「抽屉 + 导航堆栈」，`RevisionPanel` **仅**在宽屏三栏外壳条件渲染，`toggleRevisionPanel()`
  只翻转状态、窄屏界面无处呈现 → 点历史按钮**毫无反应**。修复：窄屏把同一个 `RevisionPanel`
  **整页推入**（顶栏标题「版本历史」），能力（列表 / 详情 / 一键恢复）与宽屏右侧栏完全一致；
  顶栏返回键与 Android 系统返回键均**先关面板回编辑页**、再按才退出编辑回列表（AC-137 / BR-12.3 /
  ui-spec §4.1、§6）。

### 测试

- flutter_app **50/50** 全绿（新增 `test/note_shell_narrow_test.dart` 3 项：窄屏点历史整页推入修订面板、
  顶栏返回先关面板回编辑页、系统返回两级——先关面板再退出编辑）。

## [0.8.2] - 2026-10-03

M7 补丁：移动端编辑界面简化与图片块级插入修复。

### 修复

- **移动端笔记编辑可用高度过小（B17）** — 弹出键盘后编辑区被顶栏的「格式 / 源码 / 预览」
  三态与「附件 / 历史 / 导出」按钮挤占。修复：窄屏（编辑列宽 < 520px）模式行改为**紧凑单行**——
  三态只留图标、与「历史 / 导出」压成一行并收紧上下留白，**保留格式工具栏**；原先常驻底部的
  附件条**移除**，改由格式工具栏「附件」按钮弹出**附件面板**（弹窗），为正文腾出编辑高度（AC-135）。
- **图片未作为块级内容插入正文（B18）** — 段落中插入图片后，图片**遮挡下方文字**、光标难以越过。
  根因：`EditableText` 未显式指定 `strutStyle` 时默认 `StrutStyle.fromTextStyle(style,
  forceStrutHeight: true)`，强制每一行按 strut 高度排布、**忽略较高的行内 `WidgetSpan`**，使块级
  图片溢出本行覆盖后续文字。修复：编辑器正文显式 `forceStrutHeight: false`，图片引用**独占块**
  （前后 `\n\n`）插入，块高向下撑开、后续文字整体下移、光标可越过（AC-136）。

### 测试

- flutter_app **47/47** 全绿（`test/editor_layout_test.dart` 3 项：窄屏紧凑模式行、宽屏保留文本标签、
  附件弹窗开合；`test/editor_format_image_test.dart` 新增块级图片下方留出行高断言）。
- note_core **123/123** 全绿（`test/editor_format_test.dart` 新增 `ImageBlockInsertion` 组：
  块级插入与前后空行规整）。

## [0.8.1] - 2026-10-03

M7 补丁：桌面端顶栏呈现修复。

### 修复

- **桌面端顶栏重复呈现应用标题** — 桌面端标题已由操作系统窗口标题承载（`windows/runner/main.cpp`
  的 `window.Create`），顶栏再渲染 `Text('随手记 Sui')` 属重复。修复：桌面外壳顶栏不再渲染应用
  标题文本；窄屏（`_NarrowLayout`）仍保留标题文本（AC-117）。
- **菜单栏底色与顶栏不一致（分层色块）** — `MenuBar` 默认采用 M3 `surfaceContainer` 底色、
  `elevation` 3、投影与圆角，与 AppBar 的 `colorScheme.surface` 不一致，顶栏出现分层色块。
  修复：菜单栏改为**透明叠加**——`backgroundColor` / `shadowColor` / `surfaceTintColor` 置
  `transparent`、`elevation` 置 `0`、`shape` 置直角，与顶栏底色一致（AC-117）。

### 测试

- flutter_app 41/41 全绿（`test/desktop_shell_test.dart` 12 项：新增「桌面端不呈现标题」
  与「菜单栏底色透明」断言）。

## [0.8.0] - 2026-10-03

M7 里程碑：桌面端界面布局优化。

### 新增

- **面板折叠与隐藏（FR-40）** — 桌面端（Windows / macOS / Linux）左侧栏（笔记本树）与中间栏
  （笔记列表）可**分别**折叠 / 展开；折叠后面板与其分隔线**一并消失**，得到纯编辑区的沉浸写作
  体验。「全部笔记 / 收件箱 / 标签 / 归档 / 回收站」等导航入口在折叠态仍由顶栏图标按钮与
  「视图」菜单可达，上下文（当前笔记本 / 笔记）不丢失。折叠状态为**本机视图偏好**
  （`ui.leftPanelCollapsed` / `ui.noteListCollapsed`），**重启后保持**且**不进同步**（BR-40）。
- **应用菜单栏（FR-41）** — 桌面端顶栏左上角新增**自绘菜单栏**「文件 / 编辑 / 视图 / 帮助」：
  文件（新建笔记 / 新建笔记本 / 导出当前笔记 / 退出）、编辑（撤销 / 重做 / 剪切 / 复制 / 粘贴 /
  全选 / 查找笔记）、视图（折叠 / 展开左栏与中栏、全部标签 / 归档 / 回收站、格式 / 源码 / 预览、
  版本历史）、帮助（使用文档 / 关于）。菜单项与顶栏图标按钮、编辑快捷键**同源**（同一命令
  注册表 `desktopCommands`）；不可用命令**置灰**、有状态命令显示勾选、快捷键以右侧提示呈现（BR-41）。
- **编辑模式跨重启保持** — 「格式 / 源码 / 预览」编辑模式随 `ui.editorMode` 落库，重启后停在原态。
- **退出前落库** — 桌面端经菜单「退出」时先 `flushPendingEdits`（把待写内容落库）再尽力推送，
  随后退出应用，避免未落库内容丢失（窗口关闭按钮仍走系统默认行为）。

### 变更

- 桌面端顶栏折叠 / 展开左栏与中栏的**切换图标按钮**（`PanelToggles`）与菜单项同源，折叠态与
  展开态图标区分、`tooltip` 与选中态随状态变化。
- **窄屏 / 移动端 / Web 不渲染**菜单栏与折叠开关，仍走既有响应式（抽屉 + 导航堆栈）布局，
  既有单窗口导航**行为不回归**。

### 测试

- 服务端 22/22；note_core **116/116**；flutter_app **41/41**（新增
  `test/desktop_shell_test.dart` 12 项：折叠四态与上下文不丢、持久化、恢复入口、菜单命令等价
  与置灰、快捷键提示、编辑模式跨重启、窄屏不渲染、落盘失败不阻断刷新）。桌面端手测通过
  （折叠 / 展开、菜单调用命令、退出前落库、窄屏不回归）。

## [0.7.1] - 2026-10-02

### 修复

- **笔记本上移 / 下移后侧栏顺序不变** — 根因：`createNotebook` 未分配排序权重（同级
  `sortOrder` 全为 0），上移 / 下移「交换等值」等于空操作，侧栏顺序永不变化。修复：新建按
  同级 `max(sortOrder)+1` 追加；上移 / 下移改为「重排同级 + 归一化 `sortOrder` 为 `0..n-1`」
  且仅写变化行（存量全 0 数据自愈）；`listNotebooks` 补 `createdAt` / `id` 稳定排序键。

### 测试

- note_core 116/116、flutter_app 29/29 全绿。

## [0.7.0] - 2026-10-01

M6 里程碑：全页快照与离线自持剪藏。

### 新增

- **全页快照剪藏模式（FR-37）** — 剪藏接口 `POST /api/v1/clips` 新增可选 `mode`：`article`
  （默认，类 Readability 智能提取正文）/ `snapshot`（保留整页结构与文档顺序，标题 / 表格 /
  图注等按序呈现，产出**语义等价** Markdown）。两种模式产出的笔记均可在编辑器正常打开与编辑；
  幂等键仍为 `notes.source_url`，与 `mode` 无关（BR-37.5）。
- **剪藏媒体本地化（FR-38）** — 剪藏时按优先级取图地址（`src` → `data-src` / `data-original` /
  `data-lazy-src` → `srcset` 最大图），相对地址按页面 URL 解析；逐张下载 → `sha256` 内容寻址 →
  存入附件库 → 正文图片引用改写为 `sui://<sha256>`，附件映射随笔记入库（复用既有附件通道）。
  单图失败 / 超限（单图 **10 MiB**、每篇 **200** 张、总时长 **30s**）**降级保留绝对外链**，
  不阻断整篇，数量经响应 `unlocalizedImages` 回带。
- **来源失效仍可读（FR-39）** — 已本地化的图片字节存于服务端附件库，**原网页下线 / 改版 /
  图片外链失效后，剪藏笔记的正文与图片仍完整可读**，且跨端一致（其他设备按需拉取）。
- **扩展模式选择与整页采集（M6）** — Chrome 扩展浮层新增「智能提取正文 / 全页快照」分段控件
  （缺省 `article`、记住上次；右键菜单剪藏沿用上次模式）；采集时等待完整 DOM、回填 `data-src`
  等并滚动触发懒加载图片；结果反馈回带「（N 张图片未本地化）」。新增 `shared.js`，供 popup 与
  service worker 共用设置读取、采集与请求逻辑。

### 测试

- 服务端 22/22（新增 `TestClipSnapshotMode` / `TestClipMediaLocalization` /
  `TestClipMediaFailureDegrade` / `TestClipOfflineReadable`）；note_core 113/113、
  flutter_app 27/27 全绿（M6 未改动客户端共享核心与 Flutter 客户端）。

## [0.6.0] - 2026-09-30

M5 里程碑：编辑器交互与呈现增强。

### 新增

- **编辑快捷键（FR-30）** — 格式态新增与工具栏**同源**的编辑快捷键：加粗 `Ctrl+B`、斜体
  `Ctrl+I`、删除线 `Ctrl+T`、高亮 `Ctrl+Shift+H`、任务项 `Ctrl+Shift+C`、无序 / 有序列表
  `Ctrl+Shift+W` / `Ctrl+Shift+O`、引用 `Ctrl+Shift+Q`、代码块 `Ctrl+Shift+K`、分隔线
  `Ctrl+Shift+-`、链接 `Ctrl+K`、标题 1/2/3 `Ctrl+Alt+1/2/3`、缩进 / 取消缩进 `Ctrl+M` /
  `Ctrl+Shift+M`、清除格式 `Ctrl+Space`；撤销 / 重做沿用原生栈。所有快捷键命中**同一**格式化
  命令实现，保证与工具栏行为一致（BR-30.4）。
- **任务列表勾选框（FR-31）** — 格式态把 GFM 任务项 `- [ ]` / `- [x]` 渲染为可点选勾选框，
  点选仅改写方括号内字符（逐字符回写），正本其余字节不变（BR-31.2）。
- **行内高亮（FR-31）** — `==文字==` 在**格式态与预览态**均渲染为高亮底色
  （`tertiaryContainer`），源文本原样保留（BR-31.5）。
- **聚焦式呈现（FR-32）** — 光标失焦时淡隐标记、聚焦时展开；标题 / 列表 / 引用 / 代码 / 分隔线
  按块级呈现单元组织，空块回车退出；纯呈现层能力，正本字节不变（BR-32.1）。

### 测试

- 服务端 18/18、note_core 113/113、flutter_app 27/27（新增快捷键映射同源、勾选框与高亮
  逐字节往返、块级行为单测，以及编辑器增强 widget 测试与端到端「打开不编辑」跨三态逐字节
  保真用例）。

## [0.5.0] - 2026-09-30

M4 里程碑：单用户服务化与安全加固。

### 变更

- **服务模式定为单用户（FR-33）** — 一个服务实例即一个用户的笔记库；首启创建唯一账号后关闭
  自助注册（再次注册返回 403 `already-initialized`），`/api/v1/ping` 回带 `initialized`
  供客户端判定首启状态。
- **剪藏 id 幂等与去碰撞（FR-34）** — 剪藏笔记 id 改为 ≥128 bit 摘要（`clip-<32hex>`），
  不再与手写笔记共用命名空间；服务端 `notes` 表新增 `source_url` 幂等键，同 URL 复用既有
  笔记（版本递增），异 URL 各自成篇。
- **WebSocket 广播鉴权（FR-35）** — `/api/v1/ws` 端点改为须 Token 鉴权（`?token=<token>`
  或 `Authorization: Bearer`），未通过返回 401，不再向未授权客户端广播变更。
- **密码与传输安全加固（FR-36）** — 密码以 PBKDF2-HMAC-SHA256（100000 次迭代）+ 每用户
  随机盐存储、登录常量时间比对，老库明文密码首登自动升级；CORS 支持
  `SUI_ALLOWED_ORIGINS` 白名单（未配置时开发模式全允许）；会话以 `sessions` 表为唯一真源，
  支持多设备登录。

### 测试

- 服务端 18/18、note_core 97/97、flutter_app 17/17（新增 `initialized` 心跳、注册网关关闭、
  密码校验、WS 鉴权、剪藏 id 唯一性等用例）。

## [0.3.0] - 2026-09-29

M2 里程碑：整理体验与格式化编辑。

### 新增

- **归档视图（FR-25）** — 左侧栏底部新增「归档」入口，集中展示已归档笔记并支持取消归档；
  服务端 `notes` 表新增 `archived` 列，归档状态随 push/pull 跨端一致。
- **回收站（FR-26）** — 左侧栏底部新增「回收站」入口，收纳已删除（墓碑）笔记，支持查看与还原
  （原笔记本仍在则还原到原笔记本，否则回到「全部笔记」）；删除笔记本时其笔记级联进入回收站。
- **轻量格式化编辑（FR-23 / FR-24）** — 编辑器提供「格式 / 源码 / 预览」三态，正本仍为 Markdown；
  格式工具栏与图片插入 / 尺寸调整（拖拽手柄或预设）即时回写正本。
- **笔记整理与信息呈现（FR-20 / FR-21 / FR-22）** — 笔记列表元信息（创建 / 更新时间、所属笔记本、
  标签）与排序切换；笔记归属调整（移动到…）与基本操作（置顶 / 归档 / 删除）；笔记本排序与软删除；
  全部标签总览（数量统计 + 多选筛选）。
- **界面配色与布局（FR-28）** — 左侧栏底色 `RGB(34,34,38)`，中间栏与编辑栏白底；「新建笔记本」
  按钮移至左侧栏顶部。

### 修复

- **笔记本变更同步（FR-29）** — 新建 / 重命名笔记本未进入待同步队列导致跨端不一致；补齐全部
  笔记本变更的 Outbox 入队，并修正 pull 时间游标仅在笔记变更时推进的缺陷。
- **格式模式图片渲染（FR-27）** — 「格式」模式下图片引用未渲染为图片、尺寸调整无效；改为渲染
  图片呈现单元并在选中后提供尺寸手柄 / 预设。

### 测试

- 服务端 13/13、note_core 90/90、flutter_app 10/10（新增归档净荷、笔记本新建 / 重命名同步、
  格式模式图片渲染与尺寸等用例）。

## [0.2.0] - 2026-09-27

M1 里程碑：笔记本分组与标签的云端同步。

### 新增

- **服务端数据模型** — 新增 `notebooks` / `tags` / `note_tags` 三表（含 4 个索引），
  `notes` 表新增 `notebook_id` 列承载分组归属。
- **同步协议扩展** — push 请求体新增 `notebooks` / `tags` 数组，笔记条目新增
  `notebookId`（指针语义）与 `tagIds`；pull 响应回带同名数组与字段；push 响应新增
  `notebookResults` / `tagResults`，复用 `base_version` 冲突与墓碑机制。
- **客户端** — `SyncClient` 支持笔记本 / 标签入队与推进（`enqueueNotebook` /
  `enqueueTag`，冲突后刷新 base 重发），`NoteRepository` 新增远端落库与关联重建
  （`upsertRemoteNotebook` / `upsertRemoteTag` / `syncNoteTags` / `updateNoteNotebook`）。

### 测试

- 服务端 9/9、note_core 58/58（新增笔记本 / 标签净荷与冲突 6 项 + 新设备首拉 e2e 1 项）。

## [0.1.0] - 2026-09-25

首个可用版本：完成 M0–M5 五个里程碑，服务端、客户端与剪藏扩展端到端可用。

### 新增

- **M0 骨架** — monorepo 工程（顶层 `Makefile` / `README` / `.gitignore`）；Go 服务端
  健康检查与心跳（`/healthz`、`/api/v1/ping`）；Flutter 客户端壳。
- **M1 核心本地笔记** — `clients/note_core`：数据模型、drift SQLite、`BlobStore`
  抽象与 `NoteRepository`；响应式三栏 UI 与 Markdown 源码/预览双轨编辑器。
- **M2 多端同步** — 服务端同步协议（`/sync/push`、`/sync/pull`、`/blobs/{hash}`）
  与 `base_version` 冲突判定；客户端 `SyncClient`（Outbox 合并、增量拉取、冲突本地
  合并、重发）。
- **M3 修订历史** — 服务端修订列表/详情 API；客户端 `RevisionPanel` 与一键恢复
  （恢复以新修订追加，不重写历史）。
- **M4 网页剪藏** — 服务端 `POST /api/v1/clips` 类 Readability 净化 + HTML→Markdown，
  以 URL 为幂等键；Chrome MV3 扩展；客户端「收件箱」。
- **M5 多端打磨** — CORS 中间件、Blob 下载接口、WebSocket 变更广播、登录接口、
  `source_device` 同步、性能索引、Markdown 导出。

### 修复

按时间顺序记录的 8 项修复（完整背景见 [docs/architecture.md](docs/architecture.md)）：

1. 客户端可构建性 + 数据持久化（平台条件导入分层、`path_provider` 落库）。
2. 同步链路接线 + 服务端连接配置 UI（`SyncClient` 实例化并注入 `CachedBlobStore`）。
3. 附件-笔记映射跨端同步（服务端 `attachments` 表补全，映射随笔记 push/pull）。
4. 附件上传与选择器（方案 B 上行补齐：新增即传 + 同步周期补传 + 先补传再 push）。
5. 桌面/移动平台脚手架（`android` `ios` `linux` `macos` `windows`）。
6. 删除 M0 死代码 `home_page.dart`。
7. 运行命令与文档对齐（结构树、测试用例数、各端可构建性实况）。
8. 核心特性清单与实际能力对齐；补充 30s 周期兜底同步。

### 已知限制

- 关键字搜索为 `LIKE` 子串匹配，FTS5 仅架构预留（未启用）。
- 编辑为源码 / 预览双轨，富文本 WYSIWYG 未实现。
- 鉴权为演示级实现，公网部署前需加固（见 [SECURITY.md](SECURITY.md)）。

[Unreleased]: https://gitee.com/evangubo/sui/compare/v0.8.2...HEAD
[0.8.2]: https://gitee.com/evangubo/sui/releases/tag/v0.8.2
[0.8.1]: https://gitee.com/evangubo/sui/releases/tag/v0.8.1
[0.8.0]: https://gitee.com/evangubo/sui/releases/tag/v0.8.0
[0.7.1]: https://gitee.com/evangubo/sui/releases/tag/v0.7.1
[0.7.0]: https://gitee.com/evangubo/sui/releases/tag/v0.7.0
[0.6.0]: https://gitee.com/evangubo/sui/releases/tag/v0.6.0
[0.5.0]: https://gitee.com/evangubo/sui/releases/tag/v0.5.0
[0.3.0]: https://gitee.com/evangubo/sui/releases/tag/v0.3.0
[0.2.0]: https://gitee.com/evangubo/sui/releases/tag/v0.2.0
[0.1.0]: https://gitee.com/evangubo/sui/releases/tag/v0.1.0
