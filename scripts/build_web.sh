#!/bin/bash
# 在项目根目录启动本脚本 ./scripts/build_web.sh
# 重新构建静态产物
cd clients/flutter_app && flutter build web

# 停掉当前静态服务后重新托管（当前服务非守护，重启 WSL 后不会自启）
cd clients/flutter_app/build/web \
  && nohup python3 -m http.server 8000 --bind 0.0.0.0 >/tmp/sui-web.log 2>&1 &