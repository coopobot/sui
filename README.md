# 随手记 Sui

**印象笔记替代品 —— 自托管 · 离线优先 · 多端同步的现代笔记应用。**

> 项目英文名：**Sui**（意大利语"它的/所属的"，音近「随手」）

## 项目结构（monorepo）

```
sui/
├── docs/                  # 设计与规划文档（DESIGN.md）
├── server/                # Go 同步服务端（单二进制，自托管友好）
│   └── cmd/sui-server/
├── clients/
│   └── flutter_app/       # Flutter 多端客户端（Android/iOS/桌面/Web）
├── extension/             # 浏览器剪藏扩展（Manifest V3）
├── protos/                # 共享接口契约定义
└── scripts/               # 构建 / 部署脚本
```

## 当前里程碑：M0 骨架

- [x] monorepo 目录结构
- [x] Go 服务端骨架（健康检查 + 同步心跳，含测试）
- [x] 顶层构建工具（Makefile）
- [x] Flutter 客户端壳（Web 版可构建运行，含 widget 测试）
- [ ] CI

## 快速开始（服务端）

```bash
# 首次构建
cd server
go build ./cmd/sui-server/

# 运行（默认监听 :8080，可用 SUI_ADDR 覆盖）
./sui-server

# 验证
curl http://localhost:8080/healthz
curl http://localhost:8080/api/v1/ping
```

## 设计文档

完整规划与设计见 [docs/DESIGN.md](docs/DESIGN.md)。