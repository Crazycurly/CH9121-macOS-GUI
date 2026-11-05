#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != Darwin ]]; then
  echo '此腳本需要 macOS + Xcode Command Line Tools；Linux 可執行 swift test。' >&2
  exit 1
fi
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION 必須為 x.y.z'; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || exit 1
SDK="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=13.0
DIST="$ROOT/dist"
APP="$DIST/CH9121 Config.app"
mkdir -p "$DIST" "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
  xcrun swift build --configuration release --product CH9121Config \
    --triple "$ARCH-apple-macosx13.0" --sdk "$SDK" --scratch-path ".build/$ARCH"
  BIN_PATH="$(xcrun swift build --configuration release --triple "$ARCH-apple-macosx13.0" \
    --sdk "$SDK" --scratch-path ".build/$ARCH" --show-bin-path)"
  cp "$BIN_PATH/CH9121Config" "$DIST/CH9121Config-$ARCH"
done
xcrun lipo -create "$DIST/CH9121Config-arm64" "$DIST/CH9121Config-x86_64" \
  -output "$APP/Contents/MacOS/CH9121Config"
# -verify_arch consumes the remaining arguments as architecture names: input goes first.
xcrun lipo "$APP/Contents/MacOS/CH9121Config" -verify_arch arm64 x86_64
xcrun lipo "$APP/Contents/MacOS/CH9121Config" -info
chmod 755 "$APP/Contents/MacOS/CH9121Config"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CH9121Config</string>
<key>CFBundleIdentifier</key><string>org.ch9121config.macos</string>
<key>CFBundleName</key><string>CH9121 Config</string>
<key>CFBundleDisplayName</key><string>CH9121 Config</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>透過所選 Ethernet 網卡搜尋、讀取及設定你區域網路內的 CH9121 串口網路模組。</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp docs/FIRST-RUN.md "$APP/Contents/Resources/FIRST-RUN.md"
# Ad-hoc signing only. This is NOT Developer ID signing or Apple notarization.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
"$APP/Contents/MacOS/CH9121Config" --smoke-test --screenshot "$DIST/CH9121-Config-preview.png"
(
  cd "$DIST"
  ditto -c -k --sequesterRsrc --keepParent "CH9121 Config.app" "CH9121-Config-macOS-universal.zip"
)
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ch9121-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/CH9121 Config.app"
ln -s /Applications "$STAGE/Applications"
cp docs/FIRST-RUN.md "$STAGE/使用說明.md"
hdiutil create -volname 'CH9121 Config' -srcfolder "$STAGE" -ov -format UDZO \
  "$DIST/CH9121-Config-macOS-universal.dmg"
(
  cd "$DIST"
  shasum -a 256 CH9121-Config-macOS-universal.zip CH9121-Config-macOS-universal.dmg > SHA256SUMS.txt
)
echo "完成：$DIST/CH9121-Config-macOS-universal.zip"
echo '注意：這是 ad-hoc 簽署的開發版本，未經 Apple 公證。'
