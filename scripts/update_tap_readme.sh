#!/bin/bash
# update_tap_readme.sh — 在 etng/homebrew-taps 的 README 中幂等插入/更新 SubNow 章节
# 用法: bash scripts/update_tap_readme.sh <tap 根目录> [owner/repo]
# 章节固定插入在「## 仓库结构」之前；已存在则原位替换。
set -euo pipefail
cd "$(dirname "$0")/.."

TAP_DIR="${1:?用法: bash scripts/update_tap_readme.sh <tap 根目录> [owner/repo]}"
REPO="${2:-}"
if [ -z "$REPO" ]; then
    REPO="$(git config --get remote.origin.url 2>/dev/null \
        | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')" || true
fi
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "✗ 无法确定 GitHub 仓库，请传入 owner/repo"
    exit 1
fi

README="$TAP_DIR/README.md"
if [ ! -f "$README" ]; then
    echo "✗ 找不到 $README"
    exit 1
fi

BLOCK="$(mktemp)"
FINAL="$(mktemp)"
trap 'rm -f "$BLOCK" "$FINAL"' EXIT

cat > "$BLOCK" <<'EOF'
## SubNow

菜单栏字幕助手：检测 mpv / IINA 播放的无中文字幕视频，提醒后本地转录、翻译并热挂载双语字幕。

```bash
brew install --cask etng/taps/subnow
brew upgrade --cask subnow
```

Apple Silicon，最低 macOS 14（Sonoma）。应用为 ad-hoc 签名、未做 Apple 公证；
cask 的 `postflight_steps` 会在安装后自动去掉 quarantine 标记
（等价于 `xattr -dr com.apple.quarantine /Applications/SubNow.app`）。
首次启动会引导下载 whisper 模型，模型与配置保存在 `~/Library/Application Support/SubNow`。

用法与开发说明见 → [__REPO__](https://github.com/__REPO__)

EOF

sed "s|__REPO__|${REPO}|g" "$BLOCK" > "$FINAL"

awk -v block="$FINAL" '
function emit(   line) {
    while ((getline line < block) > 0) print line
    close(block)
}
BEGIN { inserted = 0; skipping = 0 }
/^## SubNow[[:space:]]*$/ { emit(); inserted = 1; skipping = 1; next }
skipping && /^## / { skipping = 0 }
skipping { next }
!inserted && /^## 仓库结构/ { emit(); inserted = 1 }
{ print }
END { if (!inserted) { print ""; emit() } }
' "$README" > "$README.tmp"

mv "$README.tmp" "$README"
echo "✓ 已更新 $README 的 SubNow 章节"
