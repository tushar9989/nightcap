#!/bin/bash
# Builds Nightcap.app: a Mac app with its own windows (drawn by macOS's WebKit)
# around the engine in this repo. Opening it starts the engine; quitting it, or
# closing its last window, stops the engine and everything it runs.
# Needs Node and the Xcode Command Line Tools (for swiftc).
#
#   scripts/make-mac-app.sh            -> ~/Applications/Nightcap.app
#   scripts/make-mac-app.sh /some/dir  -> /some/dir/Nightcap.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  echo "Node.js not found. Install it first (brew install node)." >&2
  exit 1
fi
if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Install the Command Line Tools first (xcode-select --install)." >&2
  exit 1
fi
DEST_DIR="${1:-$HOME/Applications}"
APP="$DEST_DIR/Nightcap.app"
TMP="$(mktemp -d)"

swiftc -O -target "$(uname -m)-apple-macos13.0" -o "$TMP/Nightcap" "$ROOT/mac/Nightcap.swift"

# Icon: AppKit renders the SVG (keeping its transparent corners), then an .icns is built.
ICON=""
if swift "$ROOT/mac/render-icon.swift" "$ROOT/public/icon.svg" "$TMP/icon.png" 1024; then
  SET="$TMP/Nightcap.iconset"
  mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$TMP/Nightcap.icns" && ICON="$TMP/Nightcap.icns"
fi

rm -rf "$APP"
# The app was called Marquee before: remove that launcher if this script made it.
OLD="$DEST_DIR/Marquee.app"
if [ -f "$OLD/Contents/Info.plist" ] && grep -q "local.marquee.launcher" "$OLD/Contents/Info.plist"; then
  rm -rf "$OLD"
  echo "Removed the old $OLD"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$TMP/Nightcap" "$APP/Contents/MacOS/Nightcap"
[ -n "$ICON" ] && mv "$ICON" "$APP/Contents/Resources/Nightcap.icns"

# NightcapRoot and NightcapNode tell the app where the engine is.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nightcap</string>
  <key>CFBundleDisplayName</key><string>Nightcap</string>
  <key>CFBundleIdentifier</key><string>local.nightcap.app</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Nightcap</string>
  <key>CFBundleIconFile</key><string>Nightcap</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NightcapRoot</key><string>$ROOT</string>
  <key>NightcapNode</key><string>$NODE</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
rm -rf "$TMP"
touch "$APP"

echo "Created $APP"
echo "Open it from Finder, Launchpad or Spotlight. Drag it to the Dock to keep it there."
