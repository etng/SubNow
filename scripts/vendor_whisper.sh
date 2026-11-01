#!/bin/bash
# vendor_whisper.sh — 把 whisper.cpp 固定版本克隆进 Sources/CWhisper（只拷编译所需）
# 用法: bash scripts/vendor_whisper.sh [tag]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TAG="${1:-v1.9.5}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▶ 克隆 whisper.cpp $TAG ..."
git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp "$TMP/w"

DEST="$ROOT/Sources/CWhisper"
rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/src" "$DEST/ggml"

# 公开头文件：whisper.h + ggml 全部头（SPM 对 C/C++ target 自动公开 include/）
cp "$TMP/w/include/"*.h "$DEST/include/"
cp "$TMP/w/ggml/include/"*.h "$DEST/include/" 2>/dev/null || true

# 源码
cp "$TMP/w/src/"*.* "$DEST/src/" 2>/dev/null || true
cp -R "$TMP/w/ggml/src/." "$DEST/ggml/"

# ggml-metal 的 Metal shader 需要作为资源随 .app 分发（不参与编译）
echo "✓ 已拷贝。关键文件:"
find "$DEST" -maxdepth 4 \( -name "whisper.cpp" -o -name "whisper.h" -o -name "ggml-metal.m" -o -name "*.metal" \) | sed 's/^/  /'
echo "— src/:"; ls "$DEST/src"
echo "— ggml/ 顶层:"; ls "$DEST/ggml"
