#!/usr/bin/env bash
# scripts/package_extension.sh —— 随手记 Sui 剪藏扩展：一键打包（非源码加载）
#
# 产出到 extension/dist/（**已 gitignore**）：
#   sui-clipper-<版本>.zip      扩展目录内容，manifest.json 在 zip 根
#                               （供 Chrome Web Store 上传 / 解压后「加载已解压的扩展程序」）
#   sui-clipper-<版本>.crx      CRX3，用本地私钥签名（供自托管更新 / Chromium 直接安装）
#   update.xml                  自托管更新清单（企业策略 ExtensionInstallForcelist 用）
#   sui-clipper-<版本>.sha256   各产物 sha256（sha256sum -c 兼容）
#   INSTALL.md                  安装说明（脚本生成，不入库）
#
# 用法：bash scripts/package_extension.sh [选项]   （在仓库任意位置执行均可）
#
# 决策见 SuiDevAgent technology/adr/025-扩展分发采用ZIP与本地签名CRX3及自托管更新清单.md
# 设计见 SuiDevAgent technology/design/low-level-design/extension-packaging.md
#
# 环境变量：
#   SUI_EXT_KEY   签名私钥 PEM 路径（默认 $HOME/.sui/extension-signing-key.pem，不存在则自动生成）
#   SUI_PYTHON    python3 可执行文件（默认 python3）
#   SUI_OPENSSL   openssl 命令，可含参数（默认 openssl；与 pack_crx.py 同口径）
set -euo pipefail

# ---------------------------------------------------------------- 常量与路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC="$ROOT/extension"
PUBSPEC="$ROOT/clients/flutter_app/pubspec.yaml"
MANIFEST="$SRC/manifest.json"
PACKER="$ROOT/scripts/pack_crx.py"

PYTHON_BIN="${SUI_PYTHON:-python3}"
KEY="${SUI_EXT_KEY:-$HOME/.sui/extension-signing-key.pem}"
OUT="$SRC/dist"
APPID=""
CODEBASE=""
SKIP_CRX=0
VERSION_GATE=1
EXCLUDES=()

ok()   { printf '  [OK]   %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }

STEP=0
step() { STEP=$((STEP + 1)); printf '\n[%d/7] %s\n' "$STEP" "$*"; }

usage() {
  cat <<'USAGE'
scripts/package_extension.sh —— 随手记 Sui 剪藏扩展：一键打包（非源码加载）

产出到 extension/dist/（已 gitignore）：
  sui-clipper-<版本>.zip     扩展目录内容，manifest.json 在 zip 根
  sui-clipper-<版本>.crx     CRX3，用本地私钥签名
  update.xml                 自托管更新清单（企业策略 ExtensionInstallForcelist 用）
  sui-clipper-<版本>.sha256  各产物 sha256（sha256sum -c 兼容）
  INSTALL.md                 安装说明（脚本生成，不入库）

用法：bash scripts/package_extension.sh [选项]

选项:
  -h, --help            显示本帮助
  --out DIR             产物目录（默认 extension/dist）
  --key FILE            签名私钥 PEM（默认 ${SUI_EXT_KEY:-$HOME/.sui/extension-signing-key.pem}）
  --appid ID            update.xml 的 appid（默认：由签名公钥推导的扩展 ID）
  --codebase URL        update.xml 的 codebase（默认占位 https://example.invalid/…）
  --exclude PATTERN     额外排除条目（可重复；dist 等恒排除）
  --skip-crx            只出 zip（跳过签名 / crx / update.xml）
  --no-version-gate     跳过 scripts/version.sh check 前置门禁（不推荐，仅应急）

环境变量:
  SUI_EXT_KEY   签名私钥路径     SUI_PYTHON   python3 可执行文件
  SUI_OPENSSL   openssl 命令（可含参数）

示例:
  bash scripts/package_extension.sh
  bash scripts/package_extension.sh --codebase https://notes.example.com/ext/sui-clipper-0.13.1.crx
  bash scripts/package_extension.sh --key /secure/sui-ext.pem --out /tmp/extdist
  bash scripts/package_extension.sh --exclude test --skip-crx
USAGE
}

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)          usage; exit 0 ;;
    --out)              OUT="${2:-}"; [ -n "$OUT" ] || die "--out 需要参数"; shift 2 ;;
    --key)              KEY="${2:-}"; [ -n "$KEY" ] || die "--key 需要参数"; shift 2 ;;
    --appid)            APPID="${2:-}"; [ -n "$APPID" ] || die "--appid 需要参数"; shift 2 ;;
    --codebase)         CODEBASE="${2:-}"; [ -n "$CODEBASE" ] || die "--codebase 需要参数"; shift 2 ;;
    --exclude)          [ -n "${2:-}" ] || die "--exclude 需要参数"; EXCLUDES+=("$2"); shift 2 ;;
    --skip-crx)         SKIP_CRX=1; shift ;;
    --no-version-gate)  VERSION_GATE=0; shift ;;
    *)                  die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

# ---------------------------------------------------------------- 前置检查
[ -d "$SRC" ]      || die "扩展目录不存在：$SRC"
[ -f "$MANIFEST" ] || die "扩展清单不存在：$MANIFEST"
[ -f "$PUBSPEC" ]  || die "版本真源不存在：$PUBSPEC"
[ -f "$PACKER" ]   || die "找不到打包器：$PACKER"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "找不到 $PYTHON_BIN（可用 SUI_PYTHON 指定）"

# openssl 命令（可用 SUI_OPENSSL 覆盖，支持带参数，如 "node /path/shim.js"）
if [ -n "${SUI_OPENSSL:-}" ]; then
  # shellcheck disable=SC2206
  OSSL=(${SUI_OPENSSL})
else
  OSSL=(openssl)
fi
OSSL_BIN="${OSSL[0]}"

# pack_crx.py 的额外排除参数
EXCLUDE_ARGS=()
for e in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do EXCLUDE_ARGS+=(--exclude "$e"); done

printf '随手记 Sui · 剪藏扩展打包\n'
info "仓库根  : $ROOT"
info "产物目录: $OUT"

# ---------------------------------------------------------------- [1] 版本门禁
step "前置门禁：版本一致性（scripts/version.sh check）"
if [ "$VERSION_GATE" -eq 1 ]; then
  [ -f "$ROOT/scripts/version.sh" ] || die "找不到 $ROOT/scripts/version.sh"
  # version.sh 依赖 git / pwd 解析仓库根，故必须在仓库根执行
  if (cd "$ROOT" && bash scripts/version.sh check); then
    ok "版本门禁通过"
  else
    die "版本一致性检查未通过 —— 拒绝打包（版本漂移先修：bash scripts/version.sh set <x.y.z>）"
  fi
else
  warn "已指定 --no-version-gate，跳过版本门禁（不推荐）"
fi

# ---------------------------------------------------------------- [2] 读版本
step "读取版本（真源 = clients/flutter_app/pubspec.yaml）"
FULL_VER="$(sed -n 's/^version:[[:space:]]*//p' "$PUBSPEC" | head -1 | tr -d '[:space:]')"
[ -n "$FULL_VER" ] || die "pubspec.yaml 里没有 version: 字段"
VER="${FULL_VER%%+*}"
BN=""
[ "$FULL_VER" = "$VER" ] || BN="${FULL_VER#*+}"
[ -n "$VER" ] || die "解析版本号失败：$FULL_VER"

EXT_VER="$(grep -m1 -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$MANIFEST" | sed 's/.*"\([^"]*\)"$/\1/' || true)"
[ -n "$EXT_VER" ] || die "无法从 $MANIFEST 解析 version 字段"
[ "$EXT_VER" = "$VER" ] || die "版本不一致：pubspec=$VER 而 extension/manifest.json=$EXT_VER（门禁 C7 应已拦住）"

ok "版本 = $VER（build number ${BN:-<无>}）"
ok "extension/manifest.json 版本一致"

# ---------------------------------------------------------------- [3] 私钥
step "准备签名密钥"
ZIP="$OUT/sui-clipper-$VER.zip"
CRX="$OUT/sui-clipper-$VER.crx"
UPD="$OUT/update.xml"
SHASUM="$OUT/sui-clipper-$VER.sha256"
INSTALL_MD="$OUT/INSTALL.md"

if [ "$SKIP_CRX" -eq 1 ]; then
  info "已指定 --skip-crx：跳过签名 / crx / update.xml"
else
  command -v "$OSSL_BIN" >/dev/null 2>&1 || die "找不到 $OSSL_BIN（openssl 必需；可用 SUI_OPENSSL 指定）"
  case "$KEY" in
    "$ROOT"/*) warn "签名私钥位于仓库内（$KEY）—— 有误提交风险！建议改放 \$HOME/.sui/";;
  esac
  if [ ! -f "$KEY" ]; then
    mkdir -p "$(dirname "$KEY")"
    info "私钥不存在，生成 RSA 2048：$KEY"
    "${OSSL[@]}" genrsa -out "$KEY" 2048 >/dev/null 2>&1 || die "openssl genrsa 失败"
    ok "已生成私钥"
  else
    ok "复用已有私钥：$KEY"
  fi
  chmod 600 "$KEY" 2>/dev/null || warn "chmod 600 失败（文件系统不支持？）"
  ok "权限 600（私钥绝不入库）"
fi

mkdir -p "$OUT"

# ---------------------------------------------------------------- [4] zip
step "打 zip（manifest.json 在 zip 根）"
"$PYTHON_BIN" "$PACKER" --make-zip --source-dir "$SRC" --out "$ZIP" \
  ${EXCLUDE_ARGS[@]+"${EXCLUDE_ARGS[@]}"}
ok "zip：$ZIP"

# ---------------------------------------------------------------- [5] crx
ID=""
if [ "$SKIP_CRX" -eq 1 ]; then
  step "生成 CRX3（已跳过 --skip-crx）"
else
  step "生成 CRX3（本地私钥签名）"
  "$PYTHON_BIN" "$PACKER" --build --zip "$ZIP" --key "$KEY" --out "$CRX"
  ID="$("$PYTHON_BIN" "$PACKER" --print-id --crx "$CRX" | tail -1)"
  [[ "$ID" =~ ^[a-p]{32}$ ]] || die "扩展 ID 格式异常：$ID"
  ok "crx：$CRX"
  ok "扩展 ID：$ID"
fi

# ---------------------------------------------------------------- 计量助手
sha256_of() {
  "$PYTHON_BIN" -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}
bytes_of() { wc -c < "$1" | tr -d '[:space:]'; }
human() {
  local b="$1"
  if [ "$b" -ge 1048576 ]; then printf '%d.%d MiB' "$((b / 1048576))" "$(((b % 1048576) * 10 / 1048576))"
  elif [ "$b" -ge 1024 ]; then printf '%d.%d KiB' "$((b / 1024))" "$(((b % 1024) * 10 / 1024))"
  else printf '%s B' "$b"; fi
}

# ---------------------------------------------------------------- [6] update.xml / sha256 / INSTALL.md
step "生成 update.xml / sha256 / INSTALL.md"
if [ "$SKIP_CRX" -eq 0 ]; then
  [ -n "$CODEBASE" ] || CODEBASE="https://example.invalid/updates/sui-clipper-$VER.crx"
  if [ -n "$APPID" ]; then
    if [ "$APPID" != "$ID" ]; then
      warn "指定的 --appid ($APPID) 与签名公钥推导的扩展 ID ($ID) 不一致"
      warn "  仅当「该 crx 的 ID 由 Chrome Web Store 另行分配」时才应如此，否则 update.xml 指向错误扩展"
    fi
  else
    APPID="$ID"
  fi
  cat > "$UPD" <<XML
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$APPID'>
    <updatecheck codebase='$CODEBASE' version='$VER' />
  </app>
</gupdate>
XML
  ok "update.xml：appid=$APPID version=$VER"
  if [ "$CODEBASE" = "https://example.invalid/updates/sui-clipper-$VER.crx" ]; then
    warn "  codebase 仍为占位 URL —— 请用 --codebase 覆盖为真实可下载地址"
  fi
else
  info "已跳过 update.xml（--skip-crx）"
fi

: > "$SHASUM"
for f in "$ZIP" "$CRX" "$UPD"; do
  if [ -f "$f" ]; then
    printf '%s  %s\n' "$(sha256_of "$f")" "$(basename "$f")" >> "$SHASUM"
  fi
done
ok "sha256：$SHASUM（覆盖 zip / crx / update.xml；INSTALL.md 自身不列入，避免自指）"

# ---- INSTALL.md（随产物交付的自解释说明；生成而不入库） ----
ZIP_NAME="$(basename "$ZIP")"
ZIP_SIZE="$(human "$(bytes_of "$ZIP")")"
ZIP_SHA="$(sha256_of "$ZIP")"
SHASUM_NAME="$(basename "$SHASUM")"
SHASUM_SIZE="$(human "$(bytes_of "$SHASUM")")"
ID_SHOW="${ID:-<未签名>}"
ID_OR_PLACEHOLDER="${ID:-<ID>}"

ROW_CRX=""
ROW_UPD=""
if [ -f "$CRX" ]; then
  ROW_CRX="| \`$(basename "$CRX")\` | $(human "$(bytes_of "$CRX")") | \`$(sha256_of "$CRX")\` |
"
fi
if [ -f "$UPD" ]; then
  ROW_UPD="| \`update.xml\` | $(human "$(bytes_of "$UPD")") | \`$(sha256_of "$UPD")\` |
"
fi

cat > "$INSTALL_MD" <<MD
# 随手记 Sui · 剪藏扩展安装说明（v$VER）

本目录由 \`bash scripts/package_extension.sh\` 生成（**不入库**）。扩展 ID：\`$ID_SHOW\`

## 产物清单

| 文件 | 体积 | SHA256 |
| --- | --- | --- |
| \`$ZIP_NAME\` | $ZIP_SIZE | \`$ZIP_SHA\` |
$ROW_CRX$ROW_UPD| \`$SHASUM_NAME\` | $SHASUM_SIZE | — |

校验：\`cd extension/dist && sha256sum -c $SHASUM_NAME\`

## 三种安装路径

### ① 开发者模式「加载已解压的扩展程序」（推荐用于个人自用）

\`\`\`bash
unzip $ZIP_NAME -d /tmp/sui-clipper
\`\`\`

然后：Chrome → \`chrome://extensions\` → 打开右上角**开发者模式** → 「加载已解压的扩展程序」→
选择**解压后的目录**（含 \`manifest.json\` 的那一层）。

> 这条路径用的是**解压目录**，不是 crx；扩展 ID 由目录路径派生，与本目录里的签名 key 无关。

### ② 企业策略 + 自托管更新（受管机队）

1. 把 crx 与 \`update.xml\` 托管到 **https**（update.xml 里的 \`codebase\` 需可下载）；
2. 用管理员策略下发其一：

   - Windows 注册表
     \`HKLM\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist\1\` = \`$ID_OR_PLACEHOLDER;<update.xml 的 URL>\`
   - 或 \`ExtensionSettings\`：
     \`{"$ID_OR_PLACEHOLDER": {"installation_mode": "force_installed", "update_url": "<update.xml 的 URL>"}}\`

Chrome 会**强制安装**且用户不可禁用。要求 crx 为 **CRX3**（本目录即是）。

### ③ 上传 Chrome Web Store（对外发布）

用 \`$ZIP_NAME\`（**zip，不是 crx**）在 CWS 开发者后台上传。注意：上架后的扩展 ID
由 CWS 首次上传时确定，可能与上面的本地 ID **不同**（除非 \`manifest.json\` 含 \`"key"\`）。

## ⚠️ CRX 在桌面版 Chrome 上的限制

Chrome 桌面版（**Windows / macOS**）**不允许**从 Chrome 网上应用店之外**直接安装** \`.crx\`：
把 \`.crx\` 拖到 \`chrome://extensions\` 或双击它，Chrome 会**拒绝**并提示「只能通过 Chrome 网上应用店添加」。

这是 Google 的 off-store 安装限制，**不是**打包问题 —— 即使签名完全正确也照样被拦。
所以 \`.crx\` **不是**「给普通用户双击安装的安装包」，它只在路径 ②（企业策略）与
**Chromium / Linux 版 Chrome**（不受该限制）上有意义。

**个人自用请走路径 ①。**
MD
ok "INSTALL.md：$INSTALL_MD"

# .gitignore 覆盖自检（防御：产物绝不能入库）
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$ROOT" check-ignore -q extension/dist; then
    ok "extension/dist/ 已被 .gitignore 忽略"
  else
    warn "extension/dist/ 未被 .gitignore 忽略 —— 请追加一行 'extension/dist/'（否则产物会被误提交）"
  fi
fi

# ---------------------------------------------------------------- [7] 汇总
step "汇总"
printf '  版本     : %s（build number %s）\n' "$VER" "${BN:-<无>}"
if [ -n "$ID" ]; then
  printf '  扩展 ID  : %s\n' "$ID"
  printf '  访问前缀 : chrome-extension://%s/\n' "$ID"
fi
printf '  产物目录 : %s\n\n' "$OUT"
printf '  %-34s %10s  %s\n' '文件' '体积' 'SHA256'
for f in "$ZIP" "$CRX" "$UPD" "$SHASUM" "$INSTALL_MD"; do
  if [ -f "$f" ]; then
    printf '  %-34s %10s  %s\n' "$(basename "$f")" "$(human "$(bytes_of "$f")")" "$(sha256_of "$f")"
  fi
done
printf '\n'
if [ "$SKIP_CRX" -eq 1 ]; then
  printf '提示：本次只产出 zip（--skip-crx）。解压后用「加载已解压的扩展程序」安装。\n'
else
  printf '安装：① 解压 zip + 开发者模式「加载已解压的扩展程序」（推荐，个人自用）\n'
  printf '      ② update.xml + 企业策略 ExtensionInstallForcelist（受管机队）\n'
  printf '      ③ 上传 Chrome Web Store（用 zip；对外发布）\n'
  printf '注意：桌面版 Chrome 不允许从 Web Store 之外直接安装 .crx（拖拽 / 双击会被拦）。\n'
fi
printf '详见 %s\n' "$INSTALL_MD"
ok "打包完成"
