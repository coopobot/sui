# API 参考

Base URL：`http://<host>:8080`。受保护接口需请求头 `Authorization: Bearer <token>`。

## 端点清单

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| GET | `/healthz` | 否 | 健康检查 |
| GET | `/api/v1/ping` | 否 | 心跳（返回 `{"ok":true,"initialized":<bool>}`；`initialized` 表示是否已建号。**携带有效 Bearer 令牌时**额外返回 `instanceId`，匿名探测不返回 —— M12 / FR-55） |
| POST | `/api/v1/register` | 否 | 首启注册（单用户）：`{"username","password"}` → `{"ok","token","username"}`；建号后返回 403 |
| POST | `/api/v1/login` | 否 | 登录：`{"username","password"}` → `{"ok","token","username"}` |
| GET | `/api/v1/ws?token=<token>` | ✅ | WebSocket 变更通知（`?token=` 或 `Bearer` 鉴权） |
| POST | `/api/v1/sync/push` | ✅ | 推送批量变更（见下） |
| GET | `/api/v1/sync/pull?since=<RFC3339>` | ✅ | 增量拉取变更（响应**恒**含 `instanceId`：云端实例身份 —— M12 / FR-55） |
| PUT | `/api/v1/blobs/{hash}` | ✅ | 上传附件字节 |
| GET | `/api/v1/blobs/{hash}` | ✅ | 下载附件字节 |
| HEAD | `/api/v1/blobs/{hash}` | ✅ | 附件存在性 |
| GET | `/api/v1/notes/{id}/revisions` | ✅ | 修订列表 |
| GET | `/api/v1/notes/{id}/revisions/{version}` | ✅ | 修订详情 |
| POST | `/api/v1/clips` | ✅ | 网页剪藏：`{"url","title","html","mode"}` → 净化 + 图片本地化后入库（按 URL 幂等复用）；`mode` 取 `article`（默认，智能提取正文）/ `snapshot`（全页快照，语义等价 Markdown） |

> 本服务为**单用户**模式：仅允许创建唯一账号（首启注册后自助注册关闭，再次注册返回 403 `already-initialized`）。`/api/v1/ws` 端点须携带有效 Token（`?token=<token>` 或 `Authorization: Bearer`），未通过返回 401。

> 笔记正本 `content`（`content_markdown`）为**原样存储**的 Markdown，服务端不做语义解析：客户端编辑器新增的 GFM 任务项（`- [ ]` / `- [x]`）与高亮（`==文字==`）均作为普通文本随笔记 push/pull 逐字节往返，语义只由客户端呈现层解释。

| GET | `/api/v1/crypto/handshake` | 否 | 受保护通道握手：返回服务端长期 X25519 公钥与指纹（M10 / FR-50） |

## 健康检查与心跳

```bash
curl http://localhost:8080/healthz
# → {"ok":true,"service":"sui-server","version":"0.9.1","time":"...","initialized":false}

curl http://localhost:8080/api/v1/ping
# → {"ok":true,"service":"sui-server","version":"0.9.1","time":"...","msg":"pong","initialized":false}
```

> `initialized` 表示服务端是否已存在账号（单用户模式：建号后自助注册关闭）。首启未建号时为
> `false`，建号后为 `true`；`/healthz` 沿用同一响应壳，判定请以 `/api/v1/ping` 为准。

**`instanceId`（M12 / FR-55）**：云端实例身份，服务端首启初始化时生成并持久化于 `meta` 表，
形如 `inst-<32 位小写十六进制>`。**同一数据目录内恒定；换库 / 重建（数据目录被替换或清空重建）
必变** —— 它是客户端识别「云端已经不是原来那一份」的依据。

```bash
curl http://localhost:8080/api/v1/ping
# → {"ok":true,...,"initialized":true}                     # 匿名：不含 instanceId

curl -H "Authorization: Bearer <token>" http://localhost:8080/api/v1/ping
# → {"ok":true,...,"initialized":true,"instanceId":"inst-3f2a1b2c3d4e5f60718293a4b5c6d7e8"}
```

> `ping` 的 `instanceId` **仅在鉴权通过时**返回：匿名探测拿不到，避免对公网暴露稳定的实例指纹。
> 需要无条件获取时改用 `GET /api/v1/sync/pull`（该端点恒鉴权、恒下发）。

## 注册与登录

```bash
curl -X POST http://localhost:8080/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
# → {"ok":true,"token":"a1b2c3...","username":"me"}
```

`login` 与 `register` 请求 / 响应结构对称，用于重新获取 Token。

## 受保护通道（M10 / FR-50）

`http://` 地址下客户端可启用应用层加密（`https://` 走 TLS，不叠加）。逐请求协商、无服务端状态：

```
GET /api/v1/crypto/handshake            # 公开；返回 serverPub + fingerprint（TOFU 信任根）
→ {"ok":true,"alg":"x25519","serverPub":"<base64 32B>","fingerprint":"AB12-CD34-EF56-7890"}
```

启用后，**每个**请求带三个头，正文为密文；响应同样加密：

| 请求头 | 含义 |
|--------|------|
| `X-Sui-Enc: 1` | 声明本请求正文为通道密文 |
| `X-Sui-Eph` | 客户端本次请求的临时 X25519 公钥（base64 32B） |
| `X-Sui-Req-Id` | 本次请求的随机 id（base64 16B），用于重放拒绝 |

* `K_chan = HKDF-SHA256(ECDH(客户端临时私钥, 服务端长期公钥), salt=空, info="sui-channel-v1")`
* 正文 = `base64(ver(1) | alg(1) | nonce(12) | ct | tag(16))`；`alg=0x01` 为 AES-256-GCM
  （`0x02` ChaCha20-Poly1305 仅保留标识位，服务端不实现）
* `AAD = utf8(method + "\n" + path + "\n" + reqId)`（请求与响应用同一 AAD）
* 失败：`400 {"error":"invalid-channel"}`（不区分原因）；请求 id 重复：`409 {"error":"replayed"}`；
  未启用通道的服务端握手返回 `503 {"error":"channel-disabled"}`
* **明文请求仍然接受**（通道是加成而非强制）；WS 升级头不在通道内（已知边界，见
  [architecture.md §8.3](architecture.md#83-未实现的设计项)）
* **跨源（Flutter Web 等）**：服务端 CORS 是**白名单精确匹配、未配置默认拒绝**，需用
  `SUI_ALLOWED_ORIGINS` 列出前端来源；通道的三个自定义请求头与响应标记头 `X-Sui-Enc` 内置在
  放行 / 暴露白名单里（v0.11.2 起）。若在中间层（nginx 等）自行处理 CORS，**必须**同样放行
  `X-Sui-Enc` / `X-Sui-Eph` / `X-Sui-Req-Id` 并暴露 `X-Sui-Enc`，否则预检失败、或前端读不到
  密文标记而把密文当明文解析。
* **无正文请求（GET/HEAD）**：浏览器 `fetch` 不允许这两类方法带 body，故客户端在无正文请求上
  **只声明通道、不发封装**（正文为空）；服务端把「声明通道 + 空正文」视为**空明文**，**响应照旧加密**。
  自建客户端须遵循同一契约（否则 GET 带 body 在浏览器里会直接失败）。

## push 请求体

`items[].attachments` 可选，携带该笔记的**全部**附件映射（含墓碑，否则对端删除不收敛）。
映射只在笔记被接受（`accepted=true`）时落库；字节不在此通道，另走 `/blobs/{hash}`。

`notebooks[]` / `tags[]` 可选（M1 起），用于上行笔记本分组与标签；两者均携带 `baseVersion` /
`version` / `isDeleted` / `sourceDevice`，与笔记共用同一套冲突与墓碑机制。笔记条目的
`notebookId` 为**指针语义**：字段缺省表示不改变归属、`""` 表示移入收件箱、有值表示归属该
笔记本；`tagIds` 为该笔记标签的**全量集合**（笔记被接受时整体重建关联）；`archived` 为归档
状态（M2 起，布尔，缺省 `false`）。

```json
{
  "items": [
    {
      "id": "note-1",
      "title": "示例",
      "content": "# 标题\n正文\n![](sui://<sha256>)",
      "notebookId": "nb-1",
      "tagIds": ["tg-1"],
      "archived": false,
      "baseVersion": 3,
      "version": 4,
      "sourceDevice": "device-windows",
      "attachments": [
        {
          "id": "att-1",
          "filename": "图.png",
          "mimeKind": "image",
          "byteSize": 20480,
          "sha256": "<sha256>",
          "storageRef": "<sha256>",
          "thumbnailRef": null,
          "embeddedPos": 0,
          "isDeleted": false,
          "createdAt": "2026-09-24T07:00:00Z"
        }
      ]
    }
  ],
  "notebooks": [
    {
      "id": "nb-1",
      "parentId": "",
      "name": "工作",
      "sortOrder": 0,
      "baseVersion": 0,
      "version": 1,
      "isDeleted": false,
      "sourceDevice": "device-windows"
    }
  ],
  "tags": [
    {
      "id": "tg-1",
      "name": "重要",
      "baseVersion": 0,
      "version": 1,
      "isDeleted": false,
      "sourceDevice": "device-windows"
    }
  ]
}
```

服务端以 `baseVersion` 是否等于当前 `serverVersion` 判定冲突：

- 一致 → 应用变更，`version+1`，`accepted=true`。
- 不一致 → 返回当前 `serverVersion`，`accepted=false`，由客户端合并后重发。

## push 响应

`results` / `notebookResults` / `tagResults` 三类同构，逐条对应请求中的 `items` / `notebooks` /
`tags`；被接受时回带 `appliedVersion`；未被接受时回带 `serverVersion`（**M12 起该字段去掉
`omitempty`、恒出现**，即「服务端没有该实体」时会**显式**给出 `serverVersion: 0`）。

### 逐项裁决与客户端自愈（M12 / FR-55）

`serverVersion` 与 `notFound` 的组合即完整裁决。**第三方实现必须按此区分两种「未接受」**：

| 响应 | 含义 | 客户端应做 |
|------|------|------------|
| `accepted: true` + `appliedVersion: N` | 已应用，服务端权威版本为 N | 把该实体 `baseVersion` 更新为 N、标记已同步 |
| `accepted: false` + `notFound: true` + `serverVersion: 0` | 服务端**没有**该实体（换库 / 重建 / 回滚后不存在） | `baseVersion` **归零后立即重发**（同一轮内即会被接受）；**不要**走合并 |
| `accepted: false` + `serverVersion: N`（无 `notFound`） | **真冲突**：服务端持有该实体且权威版本为 N | 以 N 为 `baseVersion` 合并本地改动后重发；重发轮**不要**再次合并（否则冲突标记会无界膨胀） |
| `accepted: false`（响应里既无 `notFound`，也无 `serverVersion` —— 旧服务端因 `omitempty` 省略之） | 旧服务端对「没有该实体」的表达方式，解析后等价于 `serverVersion: 0` | 按「基线归零后重发」处理（向后兼容，见下方判定顺序） |

> 判定顺序：先看 `notFound`；服务端不返回该字段时，退化为「`accepted == false` 且
> `serverVersion` 缺失或为 0」即视为「服务端没有该实体」。基线本就是 0 的新实体**不会**走到这里
> （`baseVersion == 0` 时服务端直接接受）。

```json
{
  "ok": true,
  "results": [
    { "id": "note-1", "accepted": true, "appliedVersion": 4 }
  ],
  "notebookResults": [
    { "id": "nb-1", "accepted": true, "appliedVersion": 1 }
  ],
  "tagResults": [
    { "id": "tg-1", "accepted": true, "appliedVersion": 1 }
  ]
}
```

服务端**没有**该实体（换库 / 重建 / 回滚）与**真冲突**的逐项裁决长这样：

```json
{
  "ok": true,
  "results": [
    { "id": "note-1", "accepted": false, "serverVersion": 0, "notFound": true }
  ],
  "notebookResults": [
    { "id": "nb-1", "accepted": false, "serverVersion": 7 }
  ]
}
```

## pull 响应

```json
{
  "ok": true,
  "instanceId": "inst-3f2a1b2c3d4e5f60718293a4b5c6d7e8",
  "notes": [
    {
      "id": "note-1",
      "title": "示例",
      "content": "# 标题\n正文\n![](sui://<sha256>)",
      "notebookId": "nb-1",
      "tagIds": ["tg-1"],
      "archived": false,
      "version": 4,
      "isDeleted": false,
      "sourceDevice": "clip:web-extension",
      "updatedAt": "2026-09-24T08:00:00Z",
      "attachments": [
        {
          "id": "att-1",
          "filename": "图.png",
          "mimeKind": "image",
          "byteSize": 20480,
          "sha256": "<sha256>",
          "storageRef": "<sha256>",
          "thumbnailRef": null,
          "embeddedPos": 0,
          "isDeleted": false,
          "createdAt": "2026-09-24T07:00:00Z"
        }
      ]
    }
  ],
  "notebooks": [
    {
      "id": "nb-1",
      "parentId": "",
      "name": "工作",
      "sortOrder": 0,
      "version": 1,
      "isDeleted": false,
      "sourceDevice": "device-windows",
      "updatedAt": "2026-09-24T08:00:00Z"
    }
  ],
  "tags": [
    {
      "id": "tg-1",
      "name": "重要",
      "version": 1,
      "isDeleted": false,
      "sourceDevice": "device-windows",
      "updatedAt": "2026-09-24T08:00:00Z"
    }
  ]
}
```

`since` 为上一次拉取的时间游标（RFC3339）。首次拉取可省略或传极早时间；传极早时间（epoch）
即得到**云端全量权威态**（含墓碑），这也是客户端「核对补齐」所用的口径。

`instanceId`（M12 / FR-55）为**云端实例身份**，`pull` **恒定下发**（该端点本就恒鉴权）。
客户端应持久化它并在后续响应中比对：**一旦变化即说明云端被换库 / 重建**，此时**不要**直接上传
或覆盖本地数据（**选择前不动任何一端数据**），而是交由用户决断（见[用户指南](guides/user-guide.md)）。

## WebSocket 通知

```
GET /api/v1/ws?token=<token>
```

push / 剪藏成功后服务端广播 `{"type":"changed"}`；客户端收到后触发一次增量 pull。

## 剪藏

```bash
curl -X POST http://localhost:8080/api/v1/clips \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"url":"https://example.com/post","title":"示例文章","html":"<html>...</html>","mode":"snapshot"}'
# → {"ok":true,"noteId":"clip-...","title":"示例文章","version":1,
#    "url":"https://example.com/post","mode":"snapshot","unlocalizedImages":0}
```

- `mode` 可选：`article`（默认，智能提取正文）/ `snapshot`（全页快照，保留整页结构与顺序，
  语义等价 Markdown）；缺省等价 `article`。
- 服务端会把正文图片尽量本地化（下载 → `sha256` → 附件库 → 正文改 `sui://<sha256>`）；
  失败 / 超限的图片降级保留其绝对外链，数量经 `unlocalizedImages` 回带供扩展提示。
- 幂等键为 `notes.source_url`（与 `mode` 无关）：同 URL 重复剪藏复用既有笔记（版本递增）。
- 剪藏结果进入「收件箱」，`sourceDevice` 为 `clip:web-extension`。

## 错误约定

| 场景 | HTTP 状态 |
|------|-----------|
| 未携带 / 携带坏 Token | 401 |
| 已建号后重复注册 | 403（`already-initialized`） |
| 请求体格式错误 | 400 |
| 资源不存在 | 404 |

## 端到端示例

完整的「注册 → push → pull → 剪藏」调用序列见[代码示例](examples/api-usage.md)。
