#!/bin/zsh
# Builds bin/IPhoneCapture.app (universal). A real app bundle is needed so macOS
# offers Continuity Camera ("Import from iPhone") to the helper.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=bin/IPhoneCapture.app
TMP=$(mktemp -d)
rm -rf "$APP" bin/iphone-capture
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target arm64-apple-macos14 native/main.swift -o "$TMP/arm64"
swiftc -O -target x86_64-apple-macos14 native/main.swift -o "$TMP/x64"
lipo -create "$TMP/arm64" "$TMP/x64" -output "$APP/Contents/MacOS/iphone-capture"
rm -rf "$TMP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.vscode.iphone-capture</string>
  <key>CFBundleName</key><string>iPhone 拍照</string>
  <key>CFBundleDisplayName</key><string>iPhone 拍照</string>
  <key>CFBundleExecutable</key><string>iphone-capture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.4.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSCameraUsageDescription</key><string>用 iPhone 连续互通摄像头拍照并保存到当前文件夹。</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "built $APP"
