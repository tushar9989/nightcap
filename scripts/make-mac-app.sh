#!/bin/bash
# Builds Nightcap.app: one native Mac app, one process. Its windows are AppKit
# and SwiftUI, videos play through ffmpeg's libraries, and ffmpeg itself runs
# for intro and credits detection, previews and subtitles. ffmpeg, ffprobe and
# every library they need are copied into the app, so it runs on its own.
# Opening it starts the engine; quitting it, or closing its last window, saves
# everything and ends every ffmpeg run it started.
# Building needs the Xcode Command Line Tools and Homebrew's ffmpeg.
#
#   scripts/make-mac-app.sh            -> ~/Applications/Nightcap.app
#   scripts/make-mac-app.sh /some/dir  -> /some/dir/Nightcap.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tool in swiftc clang install_name_tool codesign; do
  if ! command -v "$tool" >/dev/null; then
    echo "$tool not found. Install the Command Line Tools first (xcode-select --install)." >&2
    exit 1
  fi
done
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
FF="$BREW/opt/ffmpeg"
if [ ! -x "$FF/bin/ffmpeg" ] || [ ! -x "$FF/bin/ffprobe" ] || [ ! -d "$FF/include/libavcodec" ]; then
  echo "Homebrew's ffmpeg not found. Install it first (brew install ffmpeg)." >&2
  exit 1
fi
DEST_DIR="${1:-$HOME/Applications}"
APP="$DEST_DIR/Nightcap.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARGET="$(uname -m)-apple-macos26.0"

# ---- The program ------------------------------------------------------------------------------

clang -O2 -target "$TARGET" -c "$ROOT/mac/engine/fdlibm.c" -o "$TMP/fdlibm.o"
clang -O2 -target "$TARGET" -I"$FF/include" -c "$ROOT/mac/player/ncdecoder.c" -o "$TMP/ncdecoder.o"
if ! swiftc -O -swift-version 5 -target "$TARGET" -module-name Nightcap -import-objc-header "$ROOT/mac/App.h" \
  "$ROOT"/mac/engine/*.swift "$ROOT"/mac/player/*.swift "$ROOT"/mac/ui/*.swift "$TMP/fdlibm.o" "$TMP/ncdecoder.o" \
  -L"$FF/lib" -lavformat -lavcodec -lavutil -lswscale -lswresample -licucore \
  -framework MediaPlayer -framework AVFoundation -Xlinker -headerpad_max_install_names \
  -o "$TMP/Nightcap" >"$TMP/build.log" 2>&1; then
  cat "$TMP/build.log" >&2
  exit 1
fi
# The libraries may need a newer macOS than the code; LSMinimumSystemVersion (below) takes the newest.
grep -v "which was built for newer version" "$TMP/build.log" || true

# ---- The bundle -------------------------------------------------------------------------------

STAGE="$TMP/Nightcap.app"
C="$STAGE/Contents"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources/bin"
mv "$TMP/Nightcap" "$C/MacOS/Nightcap"
cp "$FF/bin/ffmpeg" "$FF/bin/ffprobe" "$C/Resources/bin/"
chmod u+w "$C/Resources/bin/ffmpeg" "$C/Resources/bin/ffprobe"

# The libraries a file needs that are not part of macOS.
deps() {
  otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/' || true
}

# Every library they need, and every library those need, goes into Frameworks.
FILES=("$C/MacOS/Nightcap" "$C/Resources/bin/ffmpeg" "$C/Resources/bin/ffprobe")
SOURCES="" # "name<TAB>original" for each copied library
i=0
while [ $i -lt ${#FILES[@]} ]; do
  f="${FILES[$i]}"
  i=$((i + 1))
  while read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in
      @*)
        # A dylib's own id is listed too; anything else relative can't be followed.
        [ "$(basename "$dep")" = "$(basename "$f")" ] && continue
        echo "$f refers to $dep: don't know where that is." >&2
        exit 1
        ;;
    esac
    name="$(basename "$dep")"
    real="$(readlink -f "$dep")"
    known="$(printf '%s' "$SOURCES" | awk -F'\t' -v n="$name" '$1 == n {print $2}')"
    if [ -z "$known" ]; then
      cp "$real" "$C/Frameworks/$name"
      chmod u+w "$C/Frameworks/$name"
      FILES+=("$C/Frameworks/$name")
      SOURCES="$SOURCES$name	$real
"
    elif [ "$known" != "$real" ]; then
      echo "Two different libraries are called $name ($known, $real)." >&2
      exit 1
    fi
  done < <(deps "$f")
done

# Each file then looks for them there (@rpath) and nowhere else: Homebrew's own
# search paths (x265's @loader_path/../lib) are removed.
for f in "${FILES[@]}"; do
  args=()
  while read -r dep; do
    [ -z "$dep" ] && continue
    case "$dep" in @*) ;; *) args+=(-change "$dep" "@rpath/$(basename "$dep")") ;; esac
  done < <(deps "$f")
  while read -r rp; do
    [ -n "$rp" ] && args+=(-delete_rpath "$rp")
  done < <(otool -l "$f" | awk '/LC_RPATH/ {r = 1} r && / path / {print $2; r = 0}')
  case "$f" in
    "$C/Frameworks/"*) args+=(-id "@rpath/$(basename "$f")" -add_rpath @loader_path) ;;
    "$C/MacOS/"*) args+=(-add_rpath @executable_path/../Frameworks) ;;
    "$C/Resources/bin/"*) args+=(-add_rpath @executable_path/../../Frameworks) ;;
  esac
  if ! install_name_tool "${args[@]}" "$f" 2>"$TMP/names.log"; then
    cat "$TMP/names.log" >&2
    exit 1
  fi
done

# Nothing may point outside macOS and the app any more.
MIN=26.0
for f in "${FILES[@]}"; do
  left="$(deps "$f" | grep -v '^@rpath/' || true)"
  if [ -n "$left" ]; then
    echo "$f still refers to: $left" >&2
    exit 1
  fi
  rpaths="$(otool -l "$f" | awk '/LC_RPATH/ {r = 1} r && / path / {print $2; r = 0}' | grep -v -e '^@loader_path$' -e '^@executable_path/' -e '^/usr/lib/swift$' || true)"
  if [ -n "$rpaths" ]; then
    echo "$f still searches: $rpaths" >&2
    exit 1
  fi
  # The newest macOS any of them needs.
  v="$(otool -l "$f" | awk '/LC_BUILD_VERSION/ {b = 1} b && / minos / {print $2; exit}')"
  [ -n "$v" ] && MIN="$(printf '%s\n%s\n' "$MIN" "$v" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
done

# Icon: AppKit renders the SVG (keeping its transparent corners), then an .icns is built.
if swift "$ROOT/mac/render-icon.swift" "$ROOT/mac/icon.svg" "$TMP/icon.png" 1024; then
  SET="$TMP/Nightcap.iconset"
  mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$C/Resources/Nightcap.icns" || echo "No icon: iconutil failed." >&2
else
  echo "No icon: the SVG could not be rendered." >&2
fi

# Video files: Nightcap is offered in Finder's Open With (an alternate, so it
# takes no file type over until chosen there). Matroska, Ogg video, VOB and
# DivX have no type in macOS itself (other players declare them), so the
# app declares them too, under the same names.
DOC_TYPES=""
for t in public.movie public.mpeg-4 com.apple.m4v-video org.matroska.mkv org.webmproject.webm com.apple.quicktime-movie \
  public.avi com.microsoft.windows-media-wmv com.adobe.flash.video public.mpeg public.mpeg-2-transport-stream \
  public.avchd-mpeg-2-transport-stream public.3gpp org.xiph.ogg-video org.videolan.vob org.videolan.divx; do
  DOC_TYPES="$DOC_TYPES<string>$t</string>"
done
imported() { # identifier, description, extension
  printf '<dict><key>UTTypeIdentifier</key><string>%s</string><key>UTTypeDescription</key><string>%s</string>' "$1" "$2"
  printf '<key>UTTypeConformsTo</key><array><string>public.movie</string></array>'
  printf '<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>%s</string></array></dict></dict>' "$3"
}
IMPORTED="$(imported org.matroska.mkv "Matroska video" mkv)$(imported org.xiph.ogg-video "Ogg video" ogv)"
IMPORTED="$IMPORTED$(imported org.videolan.vob "DVD video" vob)$(imported org.videolan.divx "DivX video" divx)"

# NightcapLegacyData: the earlier Nightcap's data, which the first launch copies.
cat >"$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nightcap</string>
  <key>CFBundleDisplayName</key><string>Nightcap</string>
  <key>CFBundleIdentifier</key><string>local.nightcap.app</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>CFBundleShortVersionString</key><string>0.6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Nightcap</string>
  <key>CFBundleIconFile</key><string>Nightcap</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NightcapLegacyData</key><string>$ROOT/data</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Video</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array>$DOC_TYPES</array>
  </dict></array>
  <key>UTImportedTypeDeclarations</key>
  <array>$IMPORTED</array>
</dict>
</plist>
PLIST

# Ad hoc signatures: the libraries and tools first (changing their names broke
# theirs), then the app around them.
for f in "${FILES[@]}"; do
  codesign --force --sign - "$f" 2>"$TMP/sign.log" || { cat "$TMP/sign.log" >&2; exit 1; }
done
codesign --force --sign - "$STAGE" 2>"$TMP/sign.log" || { cat "$TMP/sign.log" >&2; exit 1; }
codesign --verify --deep --strict "$STAGE"

# ---- Install ----------------------------------------------------------------------------------

mkdir -p "$DEST_DIR"
rm -rf "$APP"
# The app was called Marquee before: remove that launcher if this script made it.
OLD="$DEST_DIR/Marquee.app"
if [ -f "$OLD/Contents/Info.plist" ] && grep -q "local.marquee.launcher" "$OLD/Contents/Info.plist"; then
  rm -rf "$OLD"
  echo "Removed the old $OLD"
fi
mv "$STAGE" "$APP"
touch "$APP"
# Finder's Open With lists it right away, not after Finder next notices it.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

echo "Created $APP ($(du -sh "$APP" | awk '{print $1}'), macOS $MIN or later)"
echo "Open it from Finder, Launchpad or Spotlight. Drag it to the Dock to keep it there."
