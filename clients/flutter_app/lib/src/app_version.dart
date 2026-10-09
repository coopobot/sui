// 本文件由 `scripts/version.sh` 生成 / 同步，**请勿手改**。
// 改版本号请用：bash scripts/version.sh set <x.y.z>
//
// 真源：clients/flutter_app/pubspec.yaml 的 `version:`（见 ADR-018 / ADR-020）。
// Flutter 运行时不暴露 pubspec，故版本号由构建期常量承载：
// 桌面端「帮助 → 关于随手记 Sui」与移动端 / Web 顶栏「更多 → 关于随手记 Sui」
// 均从此处取值，保证各端显示值与真源**逐字一致**。

/// 产品版本号前三段（`x.y.z`，如 `0.12.0`）——**不含**构建号（BR-56.2）。
const String kAppVersion = '0.12.1';

/// 构建号：`BN = major*10000 + minor*100 + patch`（`0.12.0 → 1200`）。
/// 仅用于问题定位（扩展设置页展示），客户端界面通常不显示。
const String kAppBuildNumber = '1201';
