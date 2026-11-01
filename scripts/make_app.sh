#!/bin/bash
# make_app.sh — 组装 SubNow.app（release 构建 + 图标 + Info.plist + ad-hoc 签名）
# 用法:
#   bash scripts/make_app.sh            # 构建到 dist/SubNow.app
#   bash scripts/make_app.sh --install  # 额外安装到 /Applications（先确认已有实例已退出）
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SubNow"
BID="com.y10n.subnow"
VERSION="1.0.0"
BUILD_DIR=".build/out/Products/Release"
APP="dist/${APP_NAME}.app"

echo "▶ ① Release 构建（arm64）..."
swift build -c release --arch arm64

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
    <key>CFBundleVersion</key>                 <string>${VERSION}</string>
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
    # 先确认没有运行中的实例（历史 build_app.sh 的教训：进程没死就 rm -rf 会出连环问题）
    if pgrep -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" >/dev/null 2>&1; then
        echo "✗ 检测到 ${APP_NAME} 正在运行，请先从菜单栏退出后再安装"
        exit 1
    fi
    if [ -d "/Applications/${APP_NAME}.app" ]; then
        rm -rf "/Applications/${APP_NAME}.app"
    fi
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "✓ 已安装并启动 /Applications/${APP_NAME}.app"
fi
