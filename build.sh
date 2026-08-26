#!/usr/bin/env bash
# BookStream 一键构建脚本：SPM 编译 → .app 骨架 → Info.plist → Ad-hoc 签名 → 启动
# 用法:
#   ./build.sh            # 构建并启动 BookStream.app
#   ./build.sh --no-launch  # 仅构建 .app 包，不启动
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BookStream"
CONFIGURATION="release"

echo "==> [1/4] SPM 编译 (release, Swift 6)"
swift build -c "$CONFIGURATION"

BIN_PATH="$(find ".build" -path "*/$CONFIGURATION/$APP_NAME" -type f | head -n 1)"
if [[ -z "$BIN_PATH" || ! -x "$BIN_PATH" ]]; then
    echo "错误: 未找到编译产物 $BIN_PATH" >&2
    exit 1
fi
echo "    产物: $BIN_PATH"

echo "==> [2/4] 生成 .app 目录骨架"
APP_DIR="dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "    已复制应用图标"
else
    echo "    警告: 未找到 Resources/AppIcon.icns，跳过图标"
fi

echo "==> [3/4] 写入标准 Info.plist"
# 构建标签：yyyymmdd_HHMM（如 20260818_1146），用于左下角判断是否最新版
BUILD_TAG="$(date +%Y%m%d_%H%M)"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>BookStream</string>
	<key>CFBundleIdentifier</key>
	<string>com.bookstream.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>BookStream</string>
	<key>CFBundleDisplayName</key>
	<string>BookStream</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleShortVersionString</key>
	<string>1.2.0</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_TAG</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
PLIST

echo "==> [4/4] Ad-hoc 签名"
codesign --force --sign - "$APP_DIR"

echo "==> 完成: $APP_DIR"
if [[ "${1:-}" != "--no-launch" ]]; then
    echo "==> 启动应用..."
    open "$APP_DIR"
fi
