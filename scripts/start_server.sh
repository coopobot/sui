#!/bin/bash
# 在项目根目录启动本脚本 ./scripts/start_server.sh
# 构建并后台启动 Go 服务端；日志写入 /tmp/sui-server.log
set -e

# 切到仓库根目录（无论从何处调用）
cd "$(dirname "$0")/.."

# Go SDK 可能不在默认 PATH
command -v go >/dev/null 2>&1 || export PATH="$PATH:/home/aiuser/go-sdk/go/bin"

# 监听地址与数据目录，可用环境变量覆盖
export SUI_ADDR="${SUI_ADDR:-127.0.0.1:8080}"
export SUI_DATA="${SUI_DATA:-/home/aiuser/sui-demo-data}"
export SUI_ALLOWED_ORIGINS="${SUI_ALLOWED_ORIGINS:-http://localhost:8000}"

LOG=/tmp/sui-server.log

# 构建
cd server
echo "=== go build ==="
go build -o bin/sui-server ./cmd/sui-server

# 停掉旧实例（若有）
if pkill -f 'bin/sui-server' 2>/dev/null; then
  echo "=== 已停止旧实例 ==="
  sleep 1
fi

# 后台启动
echo "=== 启动 sui-server ==="
nohup ./bin/sui-server >"$LOG" 2>&1 &
echo "addr=$SUI_ADDR  data=$SUI_DATA  pid=$!  log=$LOG"
