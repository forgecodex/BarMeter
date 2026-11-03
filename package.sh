#!/bin/bash
# 打包发布用安装镜像：dist/BarMeter-<版本>.dmg（通用二进制，Apple 芯片 + Intel 都能用）
# 用法：./package.sh
set -euo pipefail
cd "$(dirname "$0")"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
APP="build/pkg/BarMeter.app"
DMG="dist/BarMeter-$VER.dmg"

rm -rf build/pkg dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

echo "▸ 编译 arm64 + x86_64 …"
for A in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -target "$A-apple-macos12.0" -o "build/pkg/BarMeter-$A" BarMeter.swift
done
lipo -create -output "$APP/Contents/MacOS/BarMeter" build/pkg/BarMeter-arm64 build/pkg/BarMeter-x86_64
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null

echo "▸ 制作安装镜像 …"
STAGE="build/pkg/dmg"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.png "$STAGE/.background/bg.png"

RW="build/pkg/rw.dmg"
hdiutil create -quiet -volname "BarMeter" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')"

# 用 Finder 摆好图标位置和背景；没有自动化权限时跳过，镜像照样能用
osascript <<OSA || echo "  (跳过窗口布局)"
tell application "Finder"
  tell disk "BarMeter"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:bg.png"
    set position of item "BarMeter.app" of container window to {170, 190}
    set position of item "Applications" of container window to {470, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
SetFile -a C "$MNT" 2>/dev/null || true
sync
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
echo "✓ $DMG"
