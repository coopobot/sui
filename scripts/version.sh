#!/usr/bin/env bash
# scripts/version.sh —— 「随手记 Sui」版本号单一真源工具
#
# 真源（唯一可改处）：clients/flutter_app/pubspec.yaml 的 `version:` 字段，形如 x.y.z+BN
#   派生：Windows exe 的 FileVersion/ProductVersion、Android versionName/versionCode、
#         安装包版本（Inno Setup /DMyAppVersion）、服务端 version.String（构建期 -ldflags）
#
# 用法：
#   scripts/version.sh show            打印真源与各派生目标的现值
#   scripts/version.sh check           交叉校验（任一不符即 exit 1；make build-server 的前置门禁）
#   scripts/version.sh set <x.y.z>     改版本号（只改 pubspec 与 version.go 两行）并提示后续步骤
#
# 决策见 SuiDevAgent technology/adr/018-Windows安装包采用Inno-Setup与pubspec单一版本真源.md
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PUBSPEC="$ROOT/clients/flutter_app/pubspec.yaml"
VERSION_GO="$ROOT/server/internal/version/version.go"
CHANGELOG="$ROOT/CHANGELOG.md"

ok()   { printf '  [OK]   %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
die()  { bad "$*"; exit 1; }

[ -f "$PUBSPEC" ]    || die "找不到 $PUBSPEC（请在 sui 仓库内执行）"
[ -f "$VERSION_GO" ] || die "找不到 $VERSION_GO"
[ -f "$CHANGELOG" ]  || die "找不到 $CHANGELOG"

full_version() { sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC" | head -1 | tr -d '[:space:]'; }
just_version() { local f; f="$(full_version)"; printf '%s' "${f%%+*}"; }
build_number() {
  local f; f="$(full_version)"
  if [ "$f" = "${f%%+*}" ]; then printf ''; else printf '%s' "${f#*+}"; fi
}
go_version() { sed -n 's/^var String[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$VERSION_GO" | head -1; }

# BN 规则：major*10000 + minor*100 + patch（0.10.14 -> 1014），单调递增，直接充当 Android versionCode
expected_bn_for() {
  local v="$1" ma mi pa
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 x.y.z（收到：$v）"
  IFS=. read -r ma mi pa <<<"$v"
  printf '%s' "$((10#$ma * 10000 + 10#$mi * 100 + 10#$pa))"
}

cmd_show() {
  local ver bn
  ver="$(just_version)"; bn="$(build_number)"
  echo "版本真源: $PUBSPEC"
  echo "  真源 version           : $(full_version)"
  echo "  解析版本 / build number: ${ver} / ${bn:-<缺失>}"
  echo "  规则期望 build number  : $(expected_bn_for "$ver")"
  echo "派生目标:"
  echo "  server version.go      : $(go_version)"
  if grep -q "^## \[$ver\]" "$CHANGELOG"; then
    echo "  CHANGELOG.md           : 含 '## [$ver]'"
  else
    echo "  CHANGELOG.md           : 缺少 '## [$ver]'"
  fi
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$ver" >/dev/null 2>&1; then
    echo "  git tag                : v$ver 存在"
  else
    echo "  git tag                : v$ver 不存在"
  fi
}

cmd_check() {
  local rc=0 ver bn exp gv tag dirty
  ver="$(just_version)"; bn="$(build_number)"; exp="$(expected_bn_for "$ver")"; gv="$(go_version)"
  echo "版本一致性检查（真源：$PUBSPEC）"

  if [ "$gv" = "$ver" ]; then
    ok "C1 server/internal/version/version.go = $gv（与真源一致）"
  else
    bad "C1 server/internal/version/version.go = ${gv:-<空>}，真源 = $ver"
    echo "        修复：bash scripts/version.sh set $ver"
    rc=1
  fi

  if [ -n "$bn" ] && [ "$bn" = "$exp" ]; then
    ok "C2 build number = $bn（符合规则 M*10000+m*100+p）"
  else
    bad "C2 build number = ${bn:-<缺失>}，按规则应为 $exp"
    echo "        修复：bash scripts/version.sh set $ver"
    rc=1
  fi

  if grep -q "^## \[$ver\]" "$CHANGELOG"; then
    ok "C3 CHANGELOG.md 含 '## [$ver]' 小节"
  else
    bad "C3 CHANGELOG.md 缺少 '## [$ver]' 小节"
    rc=1
  fi

  if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$ver" >/dev/null 2>&1; then
    ok "C4 git tag v$ver 存在"
  else
    warn "C4 git tag v$ver 尚未创建（提交后需补：git tag v$ver）"
  fi

  dirty="$(git -C "$ROOT" status --porcelain -- "$PUBSPEC" "$VERSION_GO" "$CHANGELOG" 2>/dev/null || true)"
  if [ -z "$dirty" ]; then
    ok "C5 版本相关文件无未提交改动"
  else
    warn "C5 版本相关文件有未提交改动："
    printf '%s\n' "$dirty" | sed 's/^/        /'
  fi

  if [ "$rc" -ne 0 ]; then
    echo "版本一致性检查未通过。"
  else
    echo "版本一致性检查通过（$ver）。"
  fi
  return "$rc"
}

cmd_set() {
  local new="${1:-}"
  [ -n "$new" ] || die "用法：scripts/version.sh set <x.y.z>"
  local bn full n
  bn="$(expected_bn_for "$new")"
  full="$new+$bn"

  n="$(grep -c '^version:' "$PUBSPEC" || true)"
  [ "$n" = "1" ] || die "pubspec.yaml 中 'version:' 行数异常（$n），中止"
  sed -i "s|^version:.*|version: $full|" "$PUBSPEC"
  ok "clients/flutter_app/pubspec.yaml -> version: $full"

  n="$(grep -c '^var String[[:space:]]*=' "$VERSION_GO" || true)"
  [ "$n" = "1" ] || die "version.go 中 'var String =' 行数异常（$n），中止"
  sed -i "s|^var String[[:space:]]*=.*|var String = \"$new\"|" "$VERSION_GO"
  ok "server/internal/version/version.go -> var String = \"$new\""

  warn "还需两步：1) CHANGELOG.md 增加 '## [$new]' 小节；2) 提交后打 tag v$new"
  echo "同步到 Windows 构建副本后，重新构建即可让 exe 属性 / Android 包版本 / 安装包版本一并更新。"
}

case "${1:-show}" in
  show)  cmd_show ;;
  check) cmd_check ;;
  set)   shift; cmd_set "${1:-}" ;;
  -h|--help|help)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "未知命令：$1（可用：show / check / set <x.y.z>）" ;;
esac
