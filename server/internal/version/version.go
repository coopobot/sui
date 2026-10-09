// Package version holds the server version.
//
// 版本号**不是**在这里手改的：本仓库的单一真源是
// clients/flutter_app/pubspec.yaml 的 `version:` 字段，经
// scripts/version.sh 同步 / 校验后，在构建期由链接器注入：
//
//	go build -ldflags "-X sui/note-server/internal/version.String=<x.y.z>" ./cmd/sui-server
//
// （`make build-server` 已自动读取 pubspec 并注入；见 Makefile 与
// technology/design/low-level-design/windows-packaging.md，决策见 ADR-018。）
//
// String 必须是**变量**而不是常量：Go 的 `-ldflags -X` 只对变量生效。
// 文件内的字面值是「最后一次同步值」兜底，仅用于未经 Makefile 的构建
// （如 `go run` / 单元测试）；注入失败不会导致版本静默错误，check 会拦住漂移。
package version

// String 是服务端版本号，构建期可被 -ldflags -X 覆盖。
var String = "0.12.1"