#!/bin/bash
# 在项目根目录启动本脚本 ./scripts/build_web.sh
# 重新构建 Web 静态产物并用 python http.server 托管（当前服务非守护，重启 WSL 后不会自启）
set -euo pipefail

# 切到仓库根目录（无论从何处调用）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 构建静态产物
echo "=== flutter build web ==="
cd clients/flutter_app
flutter build web

# 停掉旧的静态服务（没有在跑时 pkill 返回非零，忽略）
pkill -f 'python3 -m http.server' 2>/dev/null || true
sleep 0.5

# 托管产物：用**绝对路径**。
# 旧版此处写 `cd clients/flutter_app/build/web`，而此刻 cwd 已是 clients/flutter_app，
# 该相对路径必然不存在 → `&&` 短路 → 旧服务已被 pkill 杀掉、8000 端口再无人监听（Web 端整体不可用）。
WEB_DIR="$ROOT/clients/flutter_app/build/web"
if [ ! -d "$WEB_DIR" ]; then
  echo "构建产物不存在：$WEB_DIR" >&2
  exit 1
fi
cd "$WEB_DIR"
nohup python3 -m http.server 8000 --bind 0.0.0.0 >/tmp/sui-web.log 2>&1 &
sleep 1
echo "=== Web 已托管 === http://localhost:8000  pid=$!  log=/tmp/sui-web.log"
