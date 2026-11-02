#!/bin/bash
# make_dmg.sh — 构建 ad-hoc 签名的 SubNow.app 并打成 DMG
# 产物: dist/SubNow-<version>.dmg (+ .sha256)
# 依赖: scripts/make_app.sh 完成 release 构建、Info.plist 注入与签名
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
DMG="dist/SubNow-${VERSION}.dmg"
STAGE="dist/dmg-stage"
trap 'rm -rf "$STAGE"' EXIT

bash scripts/make_app.sh

echo "▶ 组装 DMG..."
rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE"
ditto "dist/SubNow.app" "$STAGE/SubNow.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "SubNow ${VERSION}" -fs HFS+ -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"
shasum -a 256 "$DMG" > "$DMG.sha256"

echo "✓ DMG: $DMG"
cat "$DMG.sha256"
