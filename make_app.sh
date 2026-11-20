#!/bin/zsh
# Builds "Monsoon Vibes.app" — a double-clickable Mac app.
# Usage: zsh make_app.sh
set -e
cd "${0:A:h}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Run: xcode-select --install"
  exit 1
fi

APP="Monsoon Vibes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling..."
swiftc -O MonsoonVibes.swift -o "$APP/Contents/MacOS/MonsoonVibes"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Monsoon Vibes</string>
    <key>CFBundleDisplayName</key>        <string>Monsoon Vibes</string>
    <key>CFBundleIdentifier</key>         <string>com.monsoonvibes.app</string>
    <key>CFBundleExecutable</key>         <string>MonsoonVibes</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>12.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Monsoon Vibes uses your approximate location only to know whether it is day or night where you are. It never leaves your Mac.</string>
    <key>NSLocationUsageDescription</key>
    <string>Monsoon Vibes uses your approximate location only to know whether it is day or night where you are. It never leaves your Mac.</string>
</dict>
</plist>
PLIST

# App icon (AppIcon.icns must sit next to this script)
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "Note: AppIcon.icns not found, building without an icon."
fi

# Ad-hoc sign so macOS (especially Apple Silicon) is happy to run it
codesign --force --deep --sign - "$APP"

echo ""
echo "🌧️ Done: $APP"
echo "Showing it in Finder now. Double-click it to start the rain,"
echo "or drag it into your Applications folder first."
echo "Quit it from the 🌧️ icon in the menu bar."
open -R "$APP"
