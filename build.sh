#!/bin/bash
# 编译 BarMeter，安装到 ~/Applications 并启动。重复运行即为升级。
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.paxfi.barmeter"
APP_NAME="BarMeter.app"
DEST="$HOME/Applications/$APP_NAME"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "没找到 Swift 编译器。请先运行：xcode-select --install  安装完再执行本脚本。"
  exit 1
fi

# Apple Silicon 一律编原生 arm64（即使终端在 Rosetta 下运行）
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ]; then ARCH=arm64; else ARCH=x86_64; fi
OUT="build/$APP_NAME"
rm -rf build
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

echo "▸ 编译（$ARCH, -O）…"
xcrun swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos12.0" \
  -o "$OUT/Contents/MacOS/BarMeter" \
  BarMeter.swift
cp Info.plist "$OUT/Contents/Info.plist"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

echo "▸ 本地签名…"
codesign --force --sign - "$OUT" >/dev/null

echo "▸ 安装到 $DEST …"
mkdir -p "$HOME/Applications"
UIDN="$(id -u)"
if launchctl print "gui/$UIDN/$LABEL" >/dev/null 2>&1; then
  # 已经由开机启动托管：替换文件后让 launchd 重启它
  rm -rf "$DEST"
  cp -R "$OUT" "$DEST"
  pkill -x BarMeter 2>/dev/null || true
  launchctl kickstart -k "gui/$UIDN/$LABEL"
else
  pkill -x BarMeter 2>/dev/null || true
  for _ in $(seq 30); do pgrep -x BarMeter >/dev/null || break; sleep 0.1; done
  rm -rf "$DEST"
  cp -R "$OUT" "$DEST"
  open "$DEST"
fi

echo "✓ 完成。看一下右上角状态栏。"
