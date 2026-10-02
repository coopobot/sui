# syntax=docker/dockerfile:1

# ── 构建阶段 ──────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

# 安装必要工具（git 用于 go mod 下载，ca-certificates 用于 HTTPS）
RUN apk add --no-cache git ca-certificates tzdata

# 设置工作目录
WORKDIR /src

# 复制 go.mod / go.sum 并下载依赖（利用 Docker 缓存）
COPY go.mod go.sum ./
RUN go mod download

# 复制服务端源码
COPY . ./

# 构建静态二进制
# - CGO_ENABLED=0：纯静态编译（modernc.org/sqlite 是纯 Go 实现，无需 CGO）
# - GOTOOLCHAIN=auto：go.mod 声明的 Go 版本高于当前工具链时自动下载
# - -ldflags="-s -w"：去掉调试信息，减小体积
RUN CGO_ENABLED=0 GOTOOLCHAIN=auto go build \
    -ldflags="-s -w" \
    -o /out/sui-server \
    ./cmd/sui-server

# ── 运行阶段 ──────────────────────────────────────────────────────────
FROM alpine:latest

# 安装运行时依赖：
# - ca-certificates：HTTPS 客户端证书
# - tzdata：时区数据
# - 增加非 root 用户提升安全性
RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -g 1000 sui \
    && adduser -u 1000 -G sui -s /bin/sh -D sui

# 从构建阶段复制二进制
COPY --from=builder /out/sui-server /usr/local/bin/sui-server

# 创建数据目录并设置权限
RUN mkdir -p /data && chown sui:sui /data

# 切换到非 root 用户
USER sui

# 环境变量（可在运行时覆盖）
ENV SUI_ADDR=0.0.0.0:8080 \
    SUI_DATA=/data

# 暴露端口
EXPOSE 8080

# 数据卷（持久化 SQLite 数据库与附件）
VOLUME ["/data"]

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

# 启动命令
ENTRYPOINT ["/usr/local/bin/sui-server"]
