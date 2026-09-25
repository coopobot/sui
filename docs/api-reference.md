# API 参考

Base URL：`http://<host>:8080`。受保护接口需请求头 `Authorization: Bearer <token>`。

## 端点清单

| 方法 | 路径 | 鉴权 | 说明 |
|------|------|------|------|
| GET | `/healthz` | 否 | 健康检查 |
| GET | `/api/v1/ping` | 否 | 心跳（返回 `{"ok":true}`） |
| POST | `/api/v1/register` | 否 | 注册：`{"username","password"}` → `{"ok","token","username"}` |
| POST | `/api/v1/login` | 否 | 登录：`{"username","password"}` → `{"ok","token","username"}` |
| GET | `/api/v1/ws` | 否* | WebSocket 变更通知（业务消息由客户端自行鉴权） |
| POST | `/api/v1/sync/push` | ✅ | 推送批量变更（见下） |
| GET | `/api/v1/sync/pull?since=<RFC3339>` | ✅ | 增量拉取变更 |
| PUT | `/api/v1/blobs/{hash}` | ✅ | 上传附件字节 |
| GET | `/api/v1/blobs/{hash}` | ✅ | 下载附件字节 |
| HEAD | `/api/v1/blobs/{hash}` | ✅ | 附件存在性 |
| GET | `/api/v1/notes/{id}/revisions` | ✅ | 修订列表 |
| GET | `/api/v1/notes/{id}/revisions/{version}` | ✅ | 修订详情 |
| POST | `/api/v1/clips` | ✅ | 网页剪藏：`{"url","title","html"}` → 净化入库 |

> \* `/api/v1/ws` 端点本身不校验 Token，业务消息的鉴权由客户端自行处理。

## 健康检查与心跳

```bash
curl http://localhost:8080/healthz
# → {"ok":true,"service":"sui-server","version":"0.1.0","time":"..."}

curl http://localhost:8080/api/v1/ping
# → {"ok":true,"service":"sui-server","version":"0.1.0","time":"...","msg":"pong"}
```

## 注册与登录

```bash
curl -X POST http://localhost:8080/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
# → {"ok":true,"token":"a1b2c3...","username":"me"}
```

`login` 与 `register` 请求 / 响应结构对称，用于重新获取 Token。

## push 请求体

`items[].attachments` 可选，携带该笔记的**全部**附件映射（含墓碑，否则对端删除不收敛）。
映射只在笔记被接受（`accepted=true`）时落库；字节不在此通道，另走 `/blobs/{hash}`。

```json
{
  "items": [
    {
      "id": "note-1",
      "title": "示例",
      "content": "# 标题\n正文\n![](sui://<sha256>)",
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
  ]
}
```

服务端以 `baseVersion` 是否等于当前 `serverVersion` 判定冲突：

- 一致 → 应用变更，`version+1`，`accepted=true`。
- 不一致 → 返回当前 `serverVersion`，`accepted=false`，由客户端合并后重发。

## pull 响应

```json
{
  "ok": true,
  "notes": [
    {
      "id": "note-1",
      "title": "示例",
      "content": "# 标题\n正文\n![](sui://<sha256>)",
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
  ]
}
```

`since` 为上一次拉取的时间游标（RFC3339）。首次拉取可省略或传极早时间。

## WebSocket 通知

```
GET /api/v1/ws
```

push / 剪藏成功后服务端广播 `{"type":"changed"}`；客户端收到后触发一次增量 pull。

## 错误约定

| 场景 | HTTP 状态 |
|------|-----------|
| 未携带 / 携带坏 Token | 401 |
| 重复注册 | 409 |
| 请求体格式错误 | 400 |
| 资源不存在 | 404 |

## 端到端示例

完整的「注册 → push → pull → 剪藏」调用序列见[代码示例](examples/api-usage.md)。
