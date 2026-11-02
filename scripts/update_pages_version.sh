#!/bin/bash
# update_pages_version.sh — 把发布版本写入 gh-pages 产品页
# 用法:
#   bash scripts/update_pages_version.sh <X.Y.Z> [--dry-run]
#
# GitHub Release 创建后由 .github/workflows/release.yml 调用。页面中
# data-site-version 标记的可见版本与 JSON-LD softwareVersion 会被替换；
# 社交图不带版本号，不需要随发版重建。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY_RUN=0
if [ "${2:-}" = "--dry-run" ]; then
    DRY_RUN=1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ 版本必须是 X.Y.Z：${VERSION:-<空>}"
    echo "  用法: bash scripts/update_pages_version.sh <X.Y.Z> [--dry-run]"
    exit 1
fi

REMOTE="${PAGES_REMOTE:-origin}"
BRANCH="${PAGES_BRANCH:-gh-pages}"
TMP="$(mktemp -d)"
rmdir "$TMP"
cleanup() {
    git worktree remove --force "$TMP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git fetch --quiet "$REMOTE" "$BRANCH"
git worktree add --quiet --detach "$TMP" "$REMOTE/$BRANCH"

FILE="$TMP/index.html"
if [ ! -f "$FILE" ]; then
    echo "✗ ${BRANCH} 分支缺少 index.html"
    exit 1
fi

sed -i.bak -E "s/(data-site-version[^>]*>)v[0-9]+\.[0-9]+\.[0-9]+/\1v${VERSION}/g" "$FILE"
sed -i.bak -E "s/(\"softwareVersion\": \")[0-9]+\.[0-9]+\.[0-9]+/\1${VERSION}/" "$FILE"
rm -f "$FILE.bak"

if grep -Eo 'data-site-version[^>]*>v[0-9]+\.[0-9]+\.[0-9]+<' "$FILE" | grep -qv ">v${VERSION}<"; then
    echo "✗ 仍有未更新的 data-site-version 标记"
    exit 1
fi
if ! grep -q "\"softwareVersion\": \"${VERSION}\"" "$FILE"; then
    echo "✗ JSON-LD softwareVersion 未更新"
    exit 1
fi

MARKERS="$(grep -c 'data-site-version[^>]*>v'"${VERSION}"'<' "$FILE" || true)"
if [ "$MARKERS" -lt 1 ]; then
    echo "✗ 未找到 data-site-version 标记"
    exit 1
fi

if git -C "$TMP" diff --quiet -- index.html; then
    echo "✓ 产品页已经是 v${VERSION}，无需更新"
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    git -C "$TMP" --no-pager diff -- index.html
    echo "（dry-run）未提交、未推送"
    exit 0
fi

if ! git -C "$TMP" config user.name >/dev/null 2>&1 || ! git -C "$TMP" config user.email >/dev/null 2>&1; then
    git -C "$TMP" config user.name "github-actions[bot]"
    git -C "$TMP" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
fi
git -C "$TMP" add index.html
git -C "$TMP" -c commit.gpgsign=false commit --quiet -m "site: 更新版本至 v${VERSION}"
git -C "$TMP" push --quiet "$REMOTE" "HEAD:${BRANCH}"

echo "✓ 产品页版本已更新为 v${VERSION}（${MARKERS} 处可见文本 + JSON-LD）"
echo "  GitHub Pages 将自动构建：https://etng.github.io/SubNow/"
