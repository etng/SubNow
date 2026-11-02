#!/bin/bash
# make_app.sh — 组装 SubNow.app（release 构建 + 图标 + Info.plist + ad-hoc 签名）
# 用法:
#   bash scripts/make_app.sh            # 构建到 dist/SubNow.app
#   bash scripts/make_app.sh --install  # 额外安装到 /Applications（先确认已有实例已退出）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SubNow"
BID="com.y10n.subnow"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || date -u +%Y%m%d%H%M)}}"
BUILD_TIME="${BUILD_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
GIT_COMMIT="${GIT_COMMIT:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"
APP="dist/${APP_NAME}.app"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ VERSION 不是合法 SemVer（需要 X.Y.Z）: $VERSION"
    exit 1
fi

echo "▶ 版本 ${VERSION}（build ${BUILD_NUMBER}，${BUILD_TIME}，${GIT_COMMIT}）"

echo "▶ ① Release 构建（arm64）..."
swift build -c release --arch arm64
BUILD_DIR="$(swift build -c release --arch arm64 --show-bin-path | tail -1)"
echo "▶ 产物目录: $BUILD_DIR"

echo "▶ ② 生成图标..."
swift scripts/make_icon.swift dist/icon-build
iconutil -c icns dist/icon-build/AppIcon.iconset -o dist/icon-build/AppIcon.icns

echo "▶ ③ 组装 .app..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/${APP_NAME}" "$APP/Contents/MacOS/"
# SPM 资源 bundle（内含 default.metallib 与 kernels 回退资源）
if [ -d "$BUILD_DIR/${APP_NAME}_CWhisper.bundle" ]; then
    cp -R "$BUILD_DIR/${APP_NAME}_CWhisper.bundle" "$APP/Contents/Resources/"
else
    echo "⚠ 未找到 ${APP_NAME}_CWhisper.bundle（Metal 资源将缺失）"
fi
cp dist/icon-build/AppIcon.icns "$APP/Contents/Resources/"
cp dist/icon-build/menubar-18.png dist/icon-build/menubar-36.png "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>             <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>              <string>${BID}</string>
    <key>CFBundleExecutable</key>              <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>             <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>   <string>6.0</string>
    <key>CFBundleShortVersionString</key>      <string>${VERSION}</string>
    <key>CFBundleVersion</key>                 <string>${BUILD_NUMBER}</string>
    <key>SUBuildTime</key>                     <string>${BUILD_TIME}</string>
    <key>SUGitCommit</key>                     <string>${GIT_COMMIT}</string>
    <key>CFBundleIconFile</key>                <string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key>       <string>zh_CN</string>
    <key>LSMinimumSystemVersion</key>          <string>14.0</string>
    <key>LSUIElement</key>                     <true/>
    <key>NSPrincipalClass</key>                <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>        <string>© 2026 y10n · SubNow</string>
    <key>LSApplicationCategoryType</key>       <string>public.app-category.utilities</string>
    <key>NSSupportsSuddenTermination</key>     <false/>
    <key>NSSupportsAutomaticTermination</key>  <false/>
    <key>ITSAppUsesNonExemptEncryption</key>   <false/>
</dict>
</plist>
PLIST

echo "▶ ④ ad-hoc 签名..."
codesign --force --sign - "$APP"

codesign --verify --strict "$APP"
echo "✓ 打包完成: $APP"

if [ "${1:-}" = "--install" ]; then
    echo "▶ ⑤ 安装到 /Applications..."
    PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
    # 运行中的实例先优雅退出（应用带 SIGTERM 处理：收尾子进程、落盘任务检查点）
    if pgrep -f "$PATTERN" >/dev/null 2>&1; then
        echo "▷ 检测到运行中的 ${APP_NAME}，发送 TERM 等待收尾…"
        pkill -TERM -f "$PATTERN" || true
        for _ in $(seq 1 60); do
            pgrep -f "$PATTERN" >/dev/null 2>&1 || break
            sleep 0.25
        done
        if pgrep -f "$PATTERN" >/dev/null 2>&1; then
            echo "✗ ${APP_NAME} 15 秒内未退出，取消安装（避免覆盖运行中的程序）"
            exit 1
        fi
        echo "✓ 旧实例已退出"
    fi
    if [ -d "/Applications/${APP_NAME}.app" ]; then
        rm -rf "/Applications/${APP_NAME}.app"
    fi
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "✓ 已安装并启动 /Applications/${APP_NAME}.app"
fi
