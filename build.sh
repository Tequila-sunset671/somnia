#!/bin/zsh
# Builds Somnia.app directly with swiftc (works without full Xcode).
set -e
cd "$(dirname "$0")"

APP="Somnia.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# App icon: (re)generate AppIcon.icns from somnia_icon.png when needed
if [ -f somnia_icon.png ] && { [ ! -f AppIcon.icns ] || [ somnia_icon.png -nt AppIcon.icns ]; }; then
  rm -rf AppIcon.iconset && mkdir AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s somnia_icon.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1
    d=$((s*2)); sips -z $d $d somnia_icon.png --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset
fi
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xcrun --sdk macosx swiftc -O -target arm64-apple-macosx14.0 \
  "$PWD"/Sources/Somnia/*.swift \
  -o "$APP/Contents/MacOS/Somnia" \
  -framework SwiftUI -framework AppKit -framework WebKit -framework Network

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Somnia</string>
    <key>CFBundleDisplayName</key><string>Somnia</string>
    <key>CFBundleExecutable</key><string>Somnia</string>
    <key>CFBundleIdentifier</key><string>com.somnia.browser</string>
    <key>CFBundleVersion</key><string>0.1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

echo "Built $APP — run:  open $APP"
