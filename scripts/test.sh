#!/usr/bin/env bash
# 统一测试入口：CLT 默认不带 XCTest，自动切到完整 Xcode 工具链。
# 用法：scripts/test.sh [swift test 参数]
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

echo "==> DEVELOPER_DIR=${DEVELOPER_DIR:-<unset>}"
echo "==> swift build"
swift build

echo "==> swift test"
swift test "$@"
