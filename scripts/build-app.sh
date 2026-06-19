#!/bin/zsh
# Builds a double-clickable Everseq.app bundle from the SPM executable.
#
#   ./scripts/build-app.sh            release build -> build/Everseq.app
#   ./scripts/build-app.sh debug      debug build (faster, for testing)
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VERSION="0.1.0"
APP="build/Everseq.app"
BIN=".build/$CONFIG/Everseq"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Everseq"

# SPM resource bundles (e.g. GRDB's) are resolved via Bundle.main.resourceURL
# when running from an app bundle.
setopt null_glob
for bundle in .build/"$CONFIG"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "Building app icon…"
# 1) Legacy .icns — the Finder/Launchpad icon on older macOS, and the ONLY icon
#    when actool isn't available. Built from the pre-composited glyph-on-squircle.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Icon/AppIconFallback.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size*2)) $((size*2)) Icon/AppIconFallback.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# 2) macOS 26 themable icon ("Icon & widget style"): compile the Icon Composer
#    source (Icon/AppIcon.icon) into Assets.car. This REQUIRES `actool`, which
#    ships ONLY with Xcode 26 — there is no Command-Line-Tools / iconutil path.
#    With actool present the icon becomes fully OS-themable (Default/Dark/Clear/
#    Tinted); without it we ship just the static .icns above (no theming).
ICON_NAME_ENTRY=""
if xcrun --find actool >/dev/null 2>&1 && [ -d Icon/AppIcon.icon ]; then
  echo "  actool found — compiling themable icon (Assets.car)…"
  if xcrun actool Icon/AppIcon.icon \
        --compile "$APP/Contents/Resources" \
        --app-icon AppIcon \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --output-partial-info-plist "$(mktemp)" >/dev/null 2>&1 \
     && [ -f "$APP/Contents/Resources/Assets.car" ]; then
    ICON_NAME_ENTRY=$'\n    <key>CFBundleIconName</key>\n    <string>AppIcon</string>'
    echo "  themable icon built ✓"
  else
    echo "  ⚠️  actool failed — falling back to the static .icns (no OS theming)."
  fi
else
  echo "  ⚠️  actool not found (needs Xcode 26). Shipping the static .icns only —"
  echo "      this icon will NOT respond to System Settings ▸ Icon & widget style."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Everseq</string>
    <key>CFBundleDisplayName</key>
    <string>Everseq</string>
    <key>CFBundleExecutable</key>
    <string>Everseq</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>$ICON_NAME_ENTRY
    <key>CFBundleIdentifier</key>
    <string>com.everseq.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local-first outliner. Your files, your graph.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: required for arm64 binaries to launch from Finder.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Done: $APP"
echo "  open $APP                            # default graph: ~/Documents/Everseq"
echo "  EVERSEQ_GRAPH=~/notes $APP/Contents/MacOS/Everseq   # custom graph"
