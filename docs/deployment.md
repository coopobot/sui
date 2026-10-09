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
| 允许的跨源来源 | **空（默认拒绝）** | `SUI_ALLOWED_ORIGINS`，逗号分隔，如 `http://localhost:8000,https://notes.example`；**Flutter Web 端必须配置**（页面与 API 不同源）。受保护通道的自定义头已在内置白名单内，无需另行放行 |

数据目录包含：

```
data/
├── sui.db          # 所有笔记 / 修订 / 用户 / 元数据（SQLite 单文件）
└── blobs/          # 附件二进制（按 sha256 分片存储，自动去重）
```

> 备份 = 拷贝整个数据目录。停止服务后复制即可。

## 3. 二进制部署

服务端使用纯 Go 实现的 SQLite（`modernc.org/sqlite`），**无需 CGO**，
编译产物是单个完全静态的二进制文件，服务器零依赖即可运行。

### 3.1 交叉编译

在本地开发机上编译目标平台的二进制：

```bash
cd server
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOTOOLCHAIN=auto \
  go build -ldflags="-s -w" -o bin/sui-server ./cmd/sui-server
```

参数说明：

| 参数 | 作用 |
|------|------|
| `CGO_ENABLED=0` | 纯静态编译，不依赖系统 C 库 |
| `GOOS` | 目标操作系统（`linux` / `darwin` / `windows`） |
| `GOARCH` | 目标架构（`amd64` / `arm64` / `386`） |
| `-ldflags="-s -w"` | 去掉调试信息，减小二进制体积约 50% |
| `GOTOOLCHAIN=auto` | go.mod 声明版本高于本机时自动下载对应工具链 |

常见目标平台组合：

| 目标服务器 | GOOS | GOARCH |
|-----------|------|--------|
| Linux x86_64（主流服务器） | `linux` | `amd64` |
| Linux ARM64（树莓派 / 鲲鹏 / 飞腾） | `linux` | `arm64` |
| macOS Intel | `darwin` | `amd64` |
| macOS Apple Silicon | `darwin` | `arm64` |
| Windows x64 | `windows` | `amd64` |

编译完成后，产物在 `server/bin/sui-server`（约 **15–20 MB**）。

### 3.2 上传并部署

将二进制传到服务器：

```bash
scp server/bin/sui-server user@your-server:/opt/sui/
```

在服务器上准备数据目录并启动：

```bash
ssh user@your-server
sudo mkdir -p /opt/sui/data
sudo chown -R user:user /opt/sui
cd /opt/sui
SUI_ADDR=0.0.0.0:8080 SUI_DATA=/opt/sui/data ./sui-server
```

> 💡 服务器上**不需要安装 Go、不需要数据库软件**，只有一个二进制 + 一个数据目录。

### 3.3 systemd 托管（推荐）

生产环境建议用 systemd 管理进程，实现开机自启、崩溃自动重启。

创建 `/etc/systemd/system/sui.service`：

```ini
[Unit]
Description=Sui Note Server
After=network.target

[Service]
Type=simple
User=sui
WorkingDirectory=/opt/sui
ExecStart=/opt/sui/sui-server
Environment=SUI_ADDR=0.0.0.0:8080
Environment=SUI_DATA=/opt/sui/data
Restart=always
RestartSec=5

# 安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/sui/data

[Install]
WantedBy=multi-user.target
```

启动并设置开机自启：

```bash
# 创建运行用户
sudo useradd -r -s /bin/false sui

# 设置数据目录权限
sudo chown -R sui:sui /opt/sui/data

# 加载并启动
sudo systemctl daemon-reload
sudo systemctl enable --now sui

# 查看状态
sudo systemctl status sui

# 查看日志
sudo journalctl -u sui -f
```

常用操作：

```bash
sudo systemctl start sui      # 启动
sudo systemctl stop sui       # 停止
sudo systemctl restart sui    # 重启
sudo systemctl disable sui    # 取消开机自启
```

### 3.4 更新版本

```bash
# 1. 上传新二进制
scp server/bin/sui-server user@your-server:/opt/sui/sui-server.new

# 2. 在服务器上替换并重启
ssh user@your-server
sudo mv /opt/sui/sui-server.new /opt/sui/sui-server
sudo chmod +x /opt/sui/sui-server
sudo systemctl restart sui
```

## 4. Docker 部署

`server/` 目录提供了 `Dockerfile`，支持直接构建镜像并容器化部署。
镜像基于 **Alpine**，采用多阶段构建，最终镜像仅约 **15 MB**。

### 4.1 构建镜像

在 `server/` 目录执行：

```bash
cd server
docker build -t sui-server:latest .
```

> 首次构建会下载 Go 工具链与依赖，耗时较长；后续构建会利用 Docker 缓存加速。

#### 国内网络加速构建

如果 Docker Hub 拉取镜像超时，可通过 `--build-arg` 指定国内镜像源：

```bash
cd server
docker build \
  --build-arg DOCKER_MIRROR=docker.m.daocloud.io/ \
  --build-arg GOPROXY=https://goproxy.cn,direct \
  --build-arg ALPINE_MIRROR=mirrors.aliyun.com \
  -t sui-server:latest .
```

| 参数 | 作用 | 示例 |
|------|------|------|
| `DOCKER_MIRROR` | Docker 镜像加速器前缀 | `docker.m.daocloud.io/` |
| `GOPROXY` | Go 模块代理 | `https://goproxy.cn,direct` |
| `ALPINE_MIRROR` | Alpine apk 包源 | `mirrors.aliyun.com` |

> 💡 也可以直接配置 Docker 守护进程的镜像加速器（一劳永逸），见
> [Docker 官方文档](https://docs.docker.com/registry/recipes/mirror/) 或搜索
> 「Docker 镜像加速」。

### 4.2 启动容器

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

### 4.3 初始化账号（注册）

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
> 忘记 Token 时可通过 `/api/v1/login` 重新获取（见 [第 5 节](#5-注册账号与-token)）。

如果容器端口不是 8080，把上面的端口号改成你映射的端口即可。

### 4.4 环境变量

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

### 4.5 健康检查

镜像内置了健康检查，每 30 秒检测一次 `/healthz`：

```bash
docker inspect --format='{{.State.Health.Status}}' sui-server
# → healthy
```

### 4.6 常用操作

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

### 4.7 Docker Compose（可选）

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

### 4.8 带 Nginx 反代的 Docker Compose（推荐）

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

#### 国内网络环境的 Compose 加速

如果 Docker Hub 拉取慢，可在 `sui-server` 的 `build` 配置里加上 `args`，并把 Nginx 镜像换成国内源：

```yaml
services:
  sui-server:
    build:
      context: ./server
      args:
        DOCKER_MIRROR: docker.m.daocloud.io/
        GOPROXY: https://goproxy.cn,direct
        ALPINE_MIRROR: mirrors.aliyun.com
    image: sui-server:latest
    # ...其余配置同上
```

启动：

```bash
docker compose build --no-cache
docker compose up -d
```

## 5. 注册账号与 Token

服务端采用最简单的 Token 鉴权模型：**一个用户、一个 Token**。

### 5.1 注册（获取 Token）

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

### 5.2 登录（重新获取 Token）

忘记 Token 或想更换时：

```bash
curl -X POST http://localhost:8080/api/v1/login \
  -H "Content-Type: application/json" \
  -d '{"username":"me","password":"secret"}'
```

## 6. 验证服务已启动

```bash
curl http://localhost:8080/healthz
# → {"ok":true,"service":"sui-server","version":"0.9.1","time":"..."}

curl http://localhost:8080/api/v1/ping
# → {"ok":true,"service":"sui-server","version":"0.9.1","time":"...","msg":"pong"}
```

两个接口都返回 JSON 且 `ok` 为 `true`，即表示服务端已就绪。

## 7. 公网 / 局域网访问

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

## 8. 备份与恢复

- **备份**：停止服务端后整体拷贝数据目录（`sui.db` + `blobs/` + **`securechan.key`**）。

  > `securechan.key` 是**受保护通道的服务端长期 X25519 私钥**（M10 / FR-50；首次启动自动生成，
  > 权限 `0600`）。它**不参与数据解密**（笔记内容由加密笔记本的锁定密码保护），但**丢失会导致通道
  > 指纹变化**：已记录旧指纹的客户端会**阻断并要求重新核对**（这正是防中间人的设计意图）。
  > 故与数据目录一并备份；轮换密钥属**破坏性运维动作**，需通知各端重新核对指纹。
- **恢复**：把数据目录放回原路径（或设置 `SUI_DATA` 指向它），重启服务即可。

## 9. 安全与生产化

> ⚠️ 当前为**演示级实现**。公网部署前必须逐项处理下列问题。

| # | 项 | 现状 | 建议 |
|---|----|------|------|
| 1 | 密码存储 | **PBKDF2 加盐哈希**（M4 落地） | 保持；后续可评估 Argon2id |
| 2 | 令牌与会话 | **30 分钟访问令牌 + 可撤销刷新令牌**（M10 / FR-49；单次使用轮换、重放即吊销会话、与 WS 连接绑定） | — |
| 3 | HTTPS | 无内置 TLS；`http://` 下客户端启用**应用层受保护通道**（M10 / FR-50，TOFU + 逐请求 AEAD） | 公网仍**建议强制 TLS**：通道保护内容，TLS 另外提供服务器身份与合规性 |
| 4 | 限流 | 无 | `register` / `login` 加速率限制，防爆破 |
| 5 | WebSocket 鉴权 | **请求头 / 子协议携带令牌且与会话绑定**（M4 + M10 §4.5；会话吊销即断开） | 升级头不在通道内 → 可改为经通道换取**一次性短时 ticket** |
| 6 | CORS | **来源白名单精确匹配，未配置 = 默认拒绝**（M10-T23；`SUI_ALLOWED_ORIGINS`，且受保护通道的 `X-Sui-Enc`/`X-Sui-Eph`/`X-Sui-Req-Id` 与响应标记头 `X-Sui-Enc` 已列入放行/暴露白名单，v0.11.2） | 生产只配自己的前端来源；Web 端跨源必须配置 |
| 7 | 资源上限 | 请求体 / 单 blob / 条目数上限与**大传输路由单独延长读写期限**（M10-T25） | nginx `client_max_body_size` 与上表对齐（双层限长） |
| 8 | 数据备份 | 手动 | 定期备份数据目录（`sui.db` + `blobs/` + `securechan.key`） |

源码位置：`server/internal/api` 与 `server/internal/store`。

## 10. 客户端接入

部署完成后，在客户端「同步设置」对话框填入服务端地址与 Token 即可（见
[用户指南 · 连接服务端](guides/user-guide.md#23-连接服务端首次配置)）；
浏览器扩展的配置见[网页剪藏](guides/web-clipper.md)。
