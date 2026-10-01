# 部署指南

本指南面向**自托管服务端**的部署者：环境要求、构建启动、反向代理、账号 Token、
备份恢复与安全加固。

## 1. 环境要求

- 任何支持 Go 1.26 的平台（Linux / macOS / Windows / NAS）
- 无需数据库软件 —— SQLite 内嵌，数据就是一个文件目录

## 2. 构建并启动

```bash
cd server
go build -o bin/sui-server ./cmd/sui-server
./bin/sui-server
```

启动后默认：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| 监听地址 | `:8080` | 用环境变量 `SUI_ADDR` 覆盖，如 `SUI_ADDR=:9000` |
| 数据目录 | `./data` | 用环境变量 `SUI_DATA` 覆盖，如 `SUI_DATA=/var/lib/sui` |

数据目录包含：

```
data/
├── sui.db          # 所有笔记 / 修订 / 用户 / 元数据（SQLite 单文件）
└── blobs/          # 附件二进制（按 sha256 分片存储，自动去重）
```

> 备份 = 拷贝整个数据目录。停止服务后复制即可。

## 3. 注册账号与 Token

服务端采用最简单的 Token 鉴权模型：**一个用户、一个 Token**。

### 3.1 注册（获取 Token）

```bash
curl -X POST http://localhost:8080/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
```

响应：

```json
{"ok":true,"token":"a1b2c3...","username":"me"}
```

记下 `token`，这是所有客户端和扩展访问服务端的凭证。

### 3.2 登录（重新获取 Token）

忘记 Token 或想更换时：

```bash
curl -X POST http://localhost:8080/api/v1/login \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
```

## 4. 验证服务已启动

```bash
curl http://localhost:8080/healthz
# → {"ok":true,"service":"sui-server","version":"0.7.0","time":"..."}

curl http://localhost:8080/api/v1/ping
# → {"ok":true,"service":"sui-server","version":"0.7.0","time":"...","msg":"pong"}
```

两个接口都返回 JSON 且 `ok` 为 `true`，即表示服务端已就绪。

## 5. 公网 / 局域网访问

多端同步需要客户端能访问到服务端：

- **局域网**：直接使用机器 IP，如 `http://192.168.1.10:8080`（注意放行防火墙端口）。
- **公网**：推荐用 Nginx / Caddy 反代并启用 HTTPS，例如：

```nginx
# Caddy
sui.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

服务端已内置 CORS 支持与 WebSocket 升级，反代时保持 `Upgrade` 头即可。

## 6. 备份与恢复

- **备份**：停止服务端后整体拷贝数据目录（`sui.db` + `blobs/`）。
- **恢复**：把数据目录放回原路径（或设置 `SUI_DATA` 指向它），重启服务即可。

## 7. 安全与生产化

> ⚠️ 当前为**演示级实现**。公网部署前必须逐项处理下列问题。

| # | 项 | 现状 | 建议 |
|---|----|------|------|
| 1 | 密码存储 | `store.LoginUser` 以明文前缀比对 | 改为 bcrypt / argon2 哈希 |
| 2 | Token 轮换 | 登录即换 token | 客户端支持重新获取；建议加 Token 过期时间 |
| 3 | HTTPS | 无内置 TLS | 生产环境强制 TLS（反代或服务端直接 TLS） |
| 4 | 限流 | 无 | `register` / `login` 加速率限制，防爆破 |
| 5 | WebSocket 鉴权 | `/api/v1/ws` 不校验 | 建议通过查询参数或子协议携带 token |
| 6 | CORS | 开发模式全允许 | 生产配置具体来源白名单（`cors.Middleware` 的 `allowedOrigins` 参数） |
| 7 | 数据备份 | 手动 | 定期备份数据目录（`sui.db` + `blobs/`） |

源码位置：`server/internal/api` 与 `server/internal/store`。

## 8. 客户端接入

部署完成后，在客户端「同步设置」对话框填入服务端地址与 Token 即可（见
[用户指南 · 连接服务端](guides/user-guide.md#23-连接服务端首次配置)）；
浏览器扩展的配置见[网页剪藏](guides/web-clipper.md)。
