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

## 3. Docker 部署

`server/` 目录提供了 `Dockerfile`，支持直接构建镜像并容器化部署。
镜像基于 **Alpine**，采用多阶段构建，最终镜像仅约 **15 MB**。

### 3.1 构建镜像

在 `server/` 目录执行：

```bash
cd server
docker build -t sui-server:latest .
```

> 首次构建会下载 Go 工具链与依赖，耗时较长；后续构建会利用 Docker 缓存加速。

### 3.2 启动容器

```bash
docker run -d \
  --name sui-server \
  -p 8080:8080 \
  -v /path/to/sui-data:/data \
  --restart unless-stopped \
  sui-server:latest
```

参数说明：

| 参数 | 说明 |
|------|------|
| `-p 8080:8080` | 映射容器 8080 端口到主机 |
| `-v /path/to/sui-data:/data` | 挂载数据卷到宿主机目录，持久化 SQLite 与附件 |
| `--restart unless-stopped` | 容器自动重启（崩溃 / 宿主机重启后自动恢复） |
| `--name sui-server` | 容器名称，方便后续管理 |

### 3.3 初始化账号（注册）

服务端启动后，需要注册一个账号以获取访问 Token。
**首次部署必做**，后续客户端和浏览器扩展都需要用这个 Token 连接服务端。

在宿主机执行（容器已映射 8080 端口）：

```bash
curl -X POST http://localhost:8080/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
```

响应示例：

```json
{"ok":true,"token":"a1b2c3d4e5f6...","username":"me"}
```

> **记下返回的 `token`**，这是所有客户端访问服务端的凭证。
> 忘记 Token 时可通过 `/api/v1/login` 重新获取（见 [第 4 节](#4-注册账号与-token)）。

如果容器端口不是 8080，把上面的端口号改成你映射的端口即可。

### 3.4 环境变量

可通过 `-e` 覆盖默认配置：

```bash
docker run -d \
  --name sui-server \
  -p 9000:8080 \
  -e SUI_ADDR=0.0.0.0:8080 \
  -v /path/to/sui-data:/data \
  sui-server:latest
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SUI_ADDR` | `0.0.0.0:8080` | 监听地址（容器内建议保持 `0.0.0.0`） |
| `SUI_DATA` | `/data` | 数据目录（对应 volume 挂载点） |

### 3.5 健康检查

镜像内置了健康检查，每 30 秒检测一次 `/healthz`：

```bash
docker inspect --format='{{.State.Health.Status}}' sui-server
# → healthy
```

### 3.6 常用操作

```bash
# 查看日志
docker logs -f sui-server

# 停止容器
docker stop sui-server

# 启动容器
docker start sui-server

# 重启容器
docker restart sui-server

# 删除容器
docker rm -f sui-server
```

### 3.7 Docker Compose（可选）

如需使用 Docker Compose，可在项目根目录创建 `docker-compose.yml`：

```yaml
services:
  sui-server:
    build: ./server
    image: sui-server:latest
    container_name: sui-server
    ports:
      - "8080:8080"
    volumes:
      - ./data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s
```

启动：

```bash
docker compose up -d
```

### 3.8 带 Nginx 反代的 Docker Compose（推荐）

生产部署建议在前面加一层 Nginx，负责：静态缓存、连接池、后续加 HTTPS 等。
项目已提供 Nginx 配置：`server/configs/nginx.conf`。

在项目根目录创建 `docker-compose.yml`：

```yaml
services:
  sui-server:
    build: ./server
    image: sui-server:latest
    container_name: sui-server
    expose:
      - "8080"          # 只对内暴露，不映射到宿主机
    volumes:
      - ./data:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 5s

  nginx:
    image: nginx:alpine
    container_name: sui-nginx
    ports:
      - "80:80"
    volumes:
      - ./server/configs/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - sui-server
    restart: unless-stopped
```

启动：

```bash
docker compose up -d
```

启动后服务端通过 Nginx 的 **80** 端口对外提供服务：

```bash
# 健康检查走 Nginx
curl http://localhost/healthz

# 注册账号
curl -X POST http://localhost/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
```

> 💡 Nginx 配置要点：
> - `/api/v1/ws` 单独配置了 WebSocket 升级头（`Upgrade` / `Connection`）和长超时
> - `client_max_body_size 100m` 支持上传大附件，按需调整
> - `proxy_set_header X-Forwarded-*` 透传真实客户端 IP
> - 如需 HTTPS，建议在此基础上加上 Let's Encrypt / certbot

## 4. 注册账号与 Token

服务端采用最简单的 Token 鉴权模型：**一个用户、一个 Token**。

### 4.1 注册（获取 Token）

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

### 4.2 登录（重新获取 Token）

忘记 Token 或想更换时：

```bash
curl -X POST http://localhost:8080/api/v1/login \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
```

## 5. 验证服务已启动

```bash
curl http://localhost:8080/healthz
# → {"ok":true,"service":"sui-server","version":"0.7.0","time":"..."}

curl http://localhost:8080/api/v1/ping
# → {"ok":true,"service":"sui-server","version":"0.7.0","time":"...","msg":"pong"}
```

两个接口都返回 JSON 且 `ok` 为 `true`，即表示服务端已就绪。

## 6. 公网 / 局域网访问

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

## 7. 备份与恢复

- **备份**：停止服务端后整体拷贝数据目录（`sui.db` + `blobs/`）。
- **恢复**：把数据目录放回原路径（或设置 `SUI_DATA` 指向它），重启服务即可。

## 8. 安全与生产化

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

## 9. 客户端接入

部署完成后，在客户端「同步设置」对话框填入服务端地址与 Token 即可（见
[用户指南 · 连接服务端](guides/user-guide.md#23-连接服务端首次配置)）；
浏览器扩展的配置见[网页剪藏](guides/web-clipper.md)。
