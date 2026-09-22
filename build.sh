#!/bin/bash
# Builds KitchenTimer.app. No Xcode needed, Command Line Tools are enough.
#   ./build.sh            → app in ./dist/KitchenTimer.app
#   ./build.sh --install  → also copies it to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/KitchenTimer.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/KitchenTimer "$APP/Contents/MacOS/KitchenTimer"
cp Resources/ring.wav "$APP/Contents/Resources/ring.wav"
[[ -f Resources/KitchenTimer.icns ]] && cp Resources/KitchenTimer.icns "$APP/Contents/Resources/KitchenTimer.icns"
# localisation: every <code>.lproj is copied whole and listed in the plist,
# so adding a language means dropping a directory into Resources
LOCALIZATIONS=""
for lproj in Resources/*.lproj; do
    [[ -d "$lproj" ]] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
    code=$(basename "$lproj" .lproj)
    LOCALIZATIONS="$LOCALIZATIONS        <string>$code</string>"$'\n'
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>KitchenTimer</string>
    <key>CFBundleDisplayName</key>     <string>Kitchen Timer</string>
    <key>CFBundleExecutable</key>      <string>KitchenTimer</string>
    <key>CFBundleIdentifier</key>      <string>eu.zvonicek.kitchentimer</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>CFBundleIconFile</key>        <string>KitchenTimer</string>
    <key>CFBundleDevelopmentRegion</key> <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
${LOCALIZATIONS}    </array>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <!-- no Dock icon, no app switcher entry -->
    <key>LSUIElement</key>             <true/>
</dict>
</plist>
PLIST

# ad-hoc signature — without it macOS kills the app after every rebuild
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "done: $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/KitchenTimer.app
    cp -R "$APP" /Applications/KitchenTimer.app
    echo "installed: /Applications/KitchenTimer.app"
fi
