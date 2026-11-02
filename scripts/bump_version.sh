#!/bin/bash
# bump_version.sh — 按 SemVer 更新仓库根目录的 VERSION（默认 patch）
# 用法:
#   bash scripts/bump_version.sh [patch|minor|major] [--dry-run]
set -euo pipefail
cd "$(dirname "$0")/.."

PART="${1:-patch}"
DRY_RUN=0
if [ "${2:-}" = "--dry-run" ] || [ "$PART" = "--dry-run" ]; then
    DRY_RUN=1
    [ "$PART" = "--dry-run" ] && PART="${2:-patch}"
fi

CURRENT="$(tr -d '[:space:]' < VERSION)"
if ! [[ "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "✗ VERSION 不是合法 SemVer（需要 X.Y.Z）: $CURRENT"
    exit 1
fi
MAJOR=$((10#${BASH_REMATCH[1]}))
MINOR=$((10#${BASH_REMATCH[2]}))
PATCH=$((10#${BASH_REMATCH[3]}))

case "$PART" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    *) echo "✗ 未知的版本段：${PART}（可选 patch|minor|major）"; exit 1 ;;
esac

NEXT="${MAJOR}.${MINOR}.${PATCH}"
if [ "$DRY_RUN" = "1" ]; then
    echo "（dry-run）${CURRENT} → ${NEXT}（${PART}）"
    exit 0
fi

printf '%s\n' "$NEXT" > VERSION
echo "✓ ${CURRENT} → ${NEXT}（${PART}）"
echo "  下一步：git add VERSION && git commit -m \"release: v$NEXT\" && git tag v$NEXT && git push origin HEAD --tags"
