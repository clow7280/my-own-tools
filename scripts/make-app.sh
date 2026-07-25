#!/bin/zsh
# 构建 release 产物并打包为 .app（菜单栏应用，无 Dock 图标）。
# 默认用自签名证书 MyOwnToolSigning 签名，保证「辅助功能」授权跨重新构建保持；
# 如需临时改用其他身份：CODESIGN_IDENTITY=- ./scripts/make-app.sh（"-" 为 ad-hoc）。
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${CODESIGN_IDENTITY:-MyOwnToolSigning}"

swift build -c release

APP="build/MyOwnTools.app"
LEGACY_APP="build/MyOwnTool.app"
rm -rf "$APP" "$LEGACY_APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/MyOwnTools "$APP/Contents/MacOS/MyOwnTools"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MyOwnTools</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.clow.myowntools</string>
    <key>CFBundleName</key><string>MyOwnTools</string>
    <key>CFBundleDisplayName</key><string>MyOwnTools</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$SIGN_IDENTITY" --identifier com.clow.myowntools "$APP"
echo "已生成 $APP（签名身份：$SIGN_IDENTITY），可拖入「应用程序」并设为登录启动项。"
