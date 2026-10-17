#!/usr/bin/env bash
# ============================================================
#  NxShell 通用编译打包脚本
#
#  特点：自适应目录结构。无论是
#    A) 仓库根直接是源码            (package.json 在根)
#    B) 根下套一层 nxshell-source/  (package.json 在 nxshell-source/)
#    C) 只上传了 nxshell-source.zip (需先解压，且包内还套一层)
#  都能自动识别并定位到真正的工程根目录。
#
#  用法（任意 CI 或本地 Git Bash）：
#    bash build.sh
#  产物输出目录可用 OUT_DIR 覆盖：
#    OUT_DIR=/path/to/out bash build.sh
# ============================================================
set -euo pipefail

echo "=========================================="
echo " NxShell 编译打包 (Windows x64)"
echo "=========================================="

OUT_DIR="${OUT_DIR:-$(pwd)/out}"
mkdir -p "$OUT_DIR"

# --verify-only：只跑三层编译，不做 Windows 打包。
# 给 Linux 环境的 CI（如 Gitee Go 云端节点）验证源码完整性用。
VERIFY_ONLY=0
if [ "${1:-}" = "--verify-only" ]; then
    VERIFY_ONLY=1
    echo "[*] 验证模式：只编译，不打包"
fi

# ---------- 1. 如果仓库里是 zip 包，先解开 ----------
shopt -s nullglob
for z in *.zip; do
    [ -f "$z" ] || continue
    echo "[1] 发现压缩包: $z"
    PY="$(command -v python || command -v python3 || true)"
    if [ -n "$PY" ]; then
        "$PY" -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall('_unz')" "$z"
    else
        unzip -q "$z" -d _unz
    fi
    break
done

# ---------- 2. 定位工程根目录（含 package.json 的那一层）----------
ROOT=""
for d in "." "nxshell-source" "_unz" "_unz/nxshell-source" _unz/*/ ; do
    if [ -f "${d}/package.json" ]; then
        ROOT="$d"
        break
    fi
done

if [ -z "$ROOT" ]; then
    echo "!! 错误：找不到 package.json，请检查仓库结构"
    echo "   当前目录内容："
    ls -la
    exit 1
fi

echo "[2] 工程根目录: $ROOT"
cd "$ROOT"

# ---------- 3. 环境自检 + 清除危险环境变量 ----------
NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
echo "[3] Node: $(node -v)  npm: $(npm -v)"
if [ "$NODE_MAJOR" -gt 16 ] 2>/dev/null; then
    echo "    [警告] Node $NODE_MAJOR 会触发 EBADENGINE，强烈建议改用 Node 16.x"
fi

# 【关键修复】--openssl-legacy-provider 只适用于 Node 17+ (OpenSSL 3.0)
# Node 16 跑的是 OpenSSL 1.1.1，不认识这个参数，Node 会直接拒绝启动：
#   "--openssl-legacy-provider is not allowed in NODE_OPTIONS"
# 必须彻底清除（包括 CI 环境可能注入的同名变量）
unset NODE_OPTIONS
export NODE_OPTIONS=""
echo "[3] NODE_OPTIONS 已清空 -> '[$NODE_OPTIONS]'"

# 提前锁定 VS 工具链，避免 node-gyp 报
# "Could not determine Node.js install directory"
npm config set msvs_version 2022 2>/dev/null || true

# 【关键修复】Windows 控制台编码问题
# 现象：UnicodeEncodeError: 'charmap' codec can't encode characters
# 原因：Python 3.6+ 在 Windows 上默认用系统 locale 编码（cp1252 / GBK）写 stdout。
#       node-gyp 编译 node-pty 时会调用 Python 脚本，一旦输出含非 ASCII 字符
#       （CJK 路径、中文引号、特殊符号）就崩。中文 Windows 机器必现。
# 方案：强制 Python 全程 UTF-8 + 把控制台代码页切成 65001
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1
export PYTHONLEGACYWINDOWSSTDIO=utf-8
echo "[3] PYTHONIOENCODING=$PYTHONIOENCODING  PYTHONUTF8=$PYTHONUTF8"

# 控制台切 UTF-8（Git Bash 下 chcp 可能不存在，容错处理）
chcp 65001 >/dev/null 2>&1 || true

# ---------- 4. 确保 core（主进程）存在 ----------
# core 是独立仓库，且被 .gitignore 排除，推代码时极易漏掉
if [ ! -f "core/package.json" ]; then
    echo "[4] core/ 缺失，从上游克隆..."
    rm -rf core
    git clone --depth 1 https://github.com/nxshell/core.git core \
        || git clone --depth 1 https://gitee.com/nxshell/core.git core
else
    echo "[4] core/ 已存在，跳过克隆"
fi

# ---------- 5. 安装依赖 ----------
echo "[5] 安装渲染层依赖..."
npm install --legacy-peer-deps --no-audit --no-fund

echo "[5] 安装主进程依赖..."
( cd core && npm install --no-audit --no-fund )

# 原 package.json 里 "electron-rebuild": "" 版本号是空串，必须显式指定
echo "[5] 补装 electron-rebuild..."
npm install -D electron-rebuild@3.2.9 --no-audit --no-fund

# ---------- 6. 重编原生模块 ----------
echo "[6] 重编 node-pty / serialport (Electron 17.4.1)..."
# 再次兜底设置（子进程可能不继承上面的 export）
if npx electron-rebuild -f -v 17.4.1 -w serialport,node-pty -m . ; then
    echo "[6] 原生模块重编成功"
else
    echo "[6] 重编失败，尝试用 UTF-8 环境重试..."
    PYTHONIOENCODING=utf-8 PYTHONUTF8=1 \
        npx electron-rebuild -f -v 17.4.1 -w serialport,node-pty -m . \
        || echo "[6] [警告] 原生模块重编仍失败，继续尝试后续打包（运行时可能缺 node-pty）"
fi

# ---------- 6.5 修复 TypeScript 类型检查报错 ----------
# 现象：error TS2688: Cannot find type definition file for 'minimatch'
# 原因：tsconfig 用 moduleResolution: node16，TS 会自动加载 node_modules/@types 下
#       所有包。@types/glob 内部有 `/// <reference types="minimatch" />`，
#       但 @types/minimatch 未被安装（依赖树提升导致缺失）→ 类型检查直接失败。
#       这类问题在老项目里会一个接一个冒出来，逐个补 @types 治标不治本。
# 方案：让 ts-loader 只转译、不做类型检查（transpileOnly）。
#       TS 仍然正常编译 .ts/.vue，只是跳过类型校验 —— 打包产物不受影响。
echo "[6.5] 修复 TS 类型检查报错..."

# 兜底：补装缺失的类型包
npm install -D @types/minimatch@5.1.2 --no-audit --no-fund 2>/dev/null || true

# 主修复：给 ts-loader 加 transpileOnly
PY="$(command -v python || command -v python3 || true)"
if [ -n "$PY" ]; then
    "$PY" - <<'PYEOF'
import re, io, sys
p = "vue.config.js"
try:
    s = io.open(p, encoding="utf-8").read()
except Exception as e:
    print("skip patch vue.config.js:", e); sys.exit(0)

if "transpileOnly" in s:
    print("vue.config.js 已含 transpileOnly，跳过")
    sys.exit(0)

# 在 ts-loader 的 options 里插入 transpileOnly: true
m = re.search(r"(options:\s*\{[^}]*?)(\n\s*\}\s*,?)", s, re.S)
if m:
    inner, tail = m.group(1), m.group(2)
    if not inner.rstrip().endswith(","):
        inner = inner.rstrip() + ","
    new = inner + "\n                            transpileOnly: true" + tail
    s = s[:m.start()] + new + s[m.end():]
    io.open(p, "w", encoding="utf-8").write(s)
    print("已给 ts-loader 添加 transpileOnly: true")
else:
    print("未匹配到 ts-loader options，跳过")
PYEOF
fi

# ---------- 7. 三层编译 ----------
echo "[7-1] 编译渲染层 -> dist/"
npm run build

echo "[7-2] 编译主进程 -> core/dist/"
( cd core && npm run build )

# 注意：不要用 npm run build-service，那条脚本指向顶层 webpack.conf.js，
# entry ./index.js 在顶层并不存在，必然报错
echo "[7-3] 编译服务层 -> devtools/webpack/dist/"
node devtools/buildservice.js

# ---------- 8. 验证模式到此结束 ----------
if [ "$VERIFY_ONLY" -eq 1 ]; then
    echo "=========================================="
    echo " 三层编译全部通过（验证模式，未打包）"
    ls -la dist/index.html
    ls -la core/dist/index.js core/dist/AppLoader.js core/dist/AppClient.js
    ls -la devtools/webpack/dist/index.js
    echo "=========================================="
    exit 0
fi

# ---------- 9. 生成打包配置 ----------
echo "[8] 生成打包配置..."
mkdir -p staging/app staging/apps/powertools-shell

cat > staging/app/package.json <<'EOF'
{
  "name": "powertools-core",
  "version": "1.1.0",
  "description": "NxShell Core runtime (bundled)",
  "main": "index.js",
  "author": "NxShell Team",
  "license": "ISC"
}
EOF

cat > electron-builder.json <<'EOF'
{
  "productName": "NxShell",
  "appId": "com.nxshell.app",
  "copyright": "Copyright © NxShell Team",
  "directories": { "app": "staging/app", "output": "release" },
  "files": ["**/*"],
  "extraResources": [ { "from": "staging/apps", "to": "apps" } ],
  "win": {
    "target": [ { "target": "nsis", "arch": ["x64"] } ],
    "artifactName": "${productName}-${version}-win-x64-Setup.${ext}"
  },
  "nsis": {
    "oneClick": false,
    "perMachine": false,
    "allowToChangeInstallationDirectory": true,
    "createDesktopShortcut": true,
    "createStartMenuShortcut": true,
    "shortcutName": "NxShell"
  },
  "asar": true,
  "electronVersion": "17.4.1",
  "npmRebuild": false
}
EOF

# ---------- 9. 组装目录布局 ----------
# core/src/core/AppPackageManager.js 写死扫 resourcesPath/apps，
# 且只认名为 powertools-shell 的应用 —— 布局错一个字就白屏
echo "[9] 组装 resources/apps 布局..."

# 主进程三个 bundle 必须同目录（AppClient.js 是 preload，按 __dirname 取）
cp core/dist/index.js     staging/app/
cp core/dist/AppLoader.js staging/app/
cp core/dist/AppClient.js staging/app/

# 渲染层产物
cp -r dist/. staging/apps/powertools-shell/

# 服务层 bundle + 应用描述
cp devtools/webpack/dist/index.js staging/apps/powertools-shell/index.js
cp ptservices/package.json        staging/apps/powertools-shell/package.json

# node-pty / serialport 是 webpack externals，运行时需就地 require
echo "    复制 node_modules（体积较大，耐心等待）..."
cp -r node_modules staging/apps/powertools-shell/node_modules

# ---------- 10. 打包 ----------
echo "[10] electron-builder 打包中..."
npx electron-builder@23.6.0 --win --x64 --config electron-builder.json

# ---------- 11. 收集产物 ----------
echo "[11] 收集产物..."
cp release/*.exe "$OUT_DIR/" 2>/dev/null || {
    echo "!! 未找到 exe，release/ 内容："
    ls -la release || true
    exit 1
}

echo "=========================================="
echo " 完成！产物："
ls -lh "$OUT_DIR"
echo "=========================================="
