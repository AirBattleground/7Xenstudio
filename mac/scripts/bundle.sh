#!/bin/bash
# Build release and assemble "7XEN Studio.app" (ad-hoc signed). Usage: scripts/bundle.sh [scratch-path] [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${1:-.build-release}"
OUT="${2:-dist}"
APP="$OUT/7XEN Studio.app"

swift build -c release --scratch-path "$SCRATCH"
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/Studio"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Studio"

# App icon (generated with CoreGraphics)
ICONDIR="$(mktemp -d)"
swift scripts/make-icon.swift "$ICONDIR" >/dev/null && cp "$ICONDIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" || echo "note: icon generation failed"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>7XEN Studio</string>
  <key>CFBundleDisplayName</key><string>7XEN Studio</string>
  <key>CFBundleIdentifier</key><string>com.7xen.studio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSRequiresAquaSystemAppearance</key><false/>
  <key>CFBundleExecutable</key><string>Studio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSCameraUsageDescription</key><string>7XEN Studio can use this Mac's camera as a video source in your scenes.</string>
  <key>NSMicrophoneUsageDescription</key><string>7XEN Studio can use this Mac's microphone as an audio source for your show.</string>
  <key>NSLocalNetworkUsageDescription</key><string>7XEN Studio receives video from phones on your local network.</string>
  <key>NSBonjourServices</key><array><string>_http._tcp</string></array>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST

for tool in mediamtx ffmpeg; do
  if [ -x "/opt/homebrew/bin/$tool" ]; then
    cp -L "/opt/homebrew/bin/$tool" "$APP/Contents/Resources/$tool"
    echo "bundled $tool"
  else
    echo "note: /opt/homebrew/bin/$tool not found; the app falls back to PATH lookups"
  fi
done

# Sign nested tools first, then the app (ad-hoc).
for f in "$APP"/Contents/Resources/*; do [ -x "$f" ] && codesign --force --sign - "$f" 2>/dev/null || true; done
codesign --force --sign - --deep "$APP"
echo "Built: $APP"
