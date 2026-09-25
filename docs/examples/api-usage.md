# API 使用示例

本文给出可直接复制执行的 `curl` 示例，覆盖健康检查、注册登录、同步推送/拉取、
附件上传下载、修订查询与网页剪藏。接口字段的完整定义见 [API 参考](../api-reference.md)。

示例假定服务端运行在 `http://127.0.0.1:8080`，可用环境变量覆盖：

```bash
export SUI=http://127.0.0.1:8080
```

## 1. 健康检查

```bash
curl -s $SUI/healthz
# → {"ok":true,"service":"sui-server","version":"0.1.0","time":"..."}

curl -s $SUI/api/v1/ping
# → {"ok":true,"service":"sui-server","version":"0.1.0","time":"...","msg":"pong"}
```

## 2. 注册账号

```bash
curl -s -X POST $SUI/api/v1/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"me","password":"secret"}'
# → {"ok":true,"token":"a1b2c3...","username":"me"}
```

## 3. 登录取 Token

```bash
TOKEN=$(curl -s -X POST $SUI/api/v1/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"me","password":"secret"}' \
  | sed -E 's/.*"token":"([^"]+)".*/\1/')
echo $TOKEN
```

后续请求通过 `Authorization` 头携带 Token：

```bash
AUTH="Authorization: Bearer $TOKEN"
```

## 4. 推送变更（push）

`POST /api/v1/sync/push`，请求体为 `items` 数组：

```bash
curl -s -X POST $SUI/api/v1/sync/push \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{
    "items": [
      {
        "id": "note-1",
        "title": "第一条笔记",
        "content": "# 标题\n通过 curl 推送的内容",
        "baseVersion": 0,
        "version": 0,
        "sourceDevice": "device-demo-1",
        "attachments": []
      }
    ]
  }'
```

- 服务端以 `baseVersion` 是否等于当前 `serverVersion` 判定冲突：
  - 一致 → 应用变更并 `version+1`，`accepted=true`；
  - 不一致 → 返回当前 `serverVersion`、`accepted=false`，由客户端合并后重发。
- 首次新建用 `baseVersion: 0`。
- `attachments` 可选，携带该笔记的**全部**附件映射（含墓碑）。

## 5. 拉取变更（pull）

`GET /api/v1/sync/pull`，`since` 为上一次拉取的时间游标（RFC3339）：

```bash
curl -s -G $SUI/api/v1/sync/pull \
  -H "$AUTH" \
  --data-urlencode 'since=1970-01-01T00:00:00Z'
```

响应返回自 `since` 以来的笔记与附件**元数据**。附件字节不在此返回，需按 `sha256`
单独获取。首次拉取可省略 `since` 或传极早时间。

## 6. 上传与下载附件

上传（内容寻址，按路径中的 `sha256` 去重）：

```bash
curl -s -X PUT "$SUI/api/v1/blobs/<sha256>" \
  -H "$AUTH" \
  --data-binary @./photo.png
```

下载：

```bash
curl -s "$SUI/api/v1/blobs/<sha256>" -H "$AUTH" -o photo.png
```

探测是否存在（不下载正文）：

```bash
curl -s -I "$SUI/api/v1/blobs/<sha256>" -H "$AUTH"
```

## 7. 版本历史（修订）

```bash
# 某条笔记的修订列表
curl -s "$SUI/api/v1/notes/note-1/revisions" -H "$AUTH"

# 单个修订详情（按版本号）
curl -s "$SUI/api/v1/notes/note-1/revisions/1" -H "$AUTH"
```

## 8. 网页剪藏

`POST /api/v1/clips`，服务端做类 Readability 净化并转 Markdown 后入库：

```bash
curl -s -X POST $SUI/api/v1/clips \
  -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com/post","title":"示例文章","html":"<html>...</html>"}'
```

剪藏结果进入「收件箱」，`sourceDevice` 形如 `clip:web-extension`。

## 9. 冲突处理流程

1. push 返回 `accepted=false` 并给出当前 `serverVersion`；
2. 调用 pull 拉取服务端最新版本；
3. 本地按启发式规则合并（标题/正文保留双方文本，附件取并集）；
4. 带新的 `baseVersion` 重新 push。

使用客户端时这一流程自动完成；仅手工调用 API 时需要自行实现。

## 相关文档

- [API 参考](../api-reference.md)
- [系统架构](../architecture.md)
- [故障排查](../troubleshooting.md)
