#!/bin/zsh
# Builds a double-clickable Knopo.app bundle from the SPM executable.
#
#   ./scripts/build-app.sh            release build -> build/Knopo.app
#   ./scripts/build-app.sh debug      debug build (faster, for testing)
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# Version fields, overridable by env (CI sets them from the git tag / run number).
# Defaults mark an untagged local build: VERSION "dev", BUILD the short commit —
# so the app reads e.g. "dev (1a2b3c)" locally and "0.2.0 (42)" from a tagged CI build.
VERSION="${VERSION:-dev}"                                              # CFBundleShortVersionString
BUILD="${BUILD:-$(git rev-parse --short HEAD 2>/dev/null || echo 0)}"  # CFBundleVersion
APP="build/Knopo.app"
BIN=".build/$CONFIG/Knopo"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Knopo"

# SPM resource bundles (e.g. GRDB's) are resolved via Bundle.main.resourceURL
# when running from an app bundle.
setopt null_glob
for bundle in .build/"$CONFIG"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Static .icns from the pre-rendered fallback PNG (used only when actool/Xcode
# isn't available — e.g. a Command-Line-Tools-only machine).
build_static_icns() {
  local iconset; iconset="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size Icon/AppIconFallback.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) Icon/AppIconFallback.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$iconset")"
}

echo "Building app icon…"
# The icon is authored in Knopo.icon (Icon Composer). With actool (Xcode) we
# compile it to BOTH:
#   • Assets.car   → macOS 26 "Icon & widget style" theming (Default/Dark/Tinted/Clear)
#   • Knopo.icns → backwards-compatible static icon used on macOS 15 and earlier
# Without actool we fall back to a static .icns from Icon/AppIconFallback.png.
ICON_FILE="AppIcon"     # CFBundleIconFile value (basename, no extension)
ICON_NAME_ENTRY=""      # optional CFBundleIconName block (only when themable)
if xcrun --find actool >/dev/null 2>&1 && [ -d Knopo.icon ]; then
  echo "  compiling Knopo.icon (themable Assets.car + backwards-compatible .icns)…"
  if xcrun actool Knopo.icon \
        --compile "$APP/Contents/Resources" \
        --app-icon Knopo \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --output-partial-info-plist "$(mktemp)" >/dev/null 2>&1 \
     && [ -f "$APP/Contents/Resources/Assets.car" ] \
     && [ -f "$APP/Contents/Resources/Knopo.icns" ]; then
    ICON_FILE="Knopo"
    ICON_NAME_ENTRY=$'\n    <key>CFBundleIconName</key>\n    <string>Knopo</string>'
    echo "  themable icon built ✓"
  else
    echo "  ⚠️  actool failed — using static .icns fallback (no theming)."
    build_static_icns
  fi
else
  echo "  actool not found (needs Xcode) — using static .icns fallback (no theming)."
  build_static_icns
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!--
      Load-bearing, not decorative: with .lproj directories present but no
      matching one for the user's language, CFBundle otherwise falls back to
      whichever localization it happens to find — a pseudo-localized test
      bundle included. With this set, an unshipped language resolves to the
      development region, and every key is already English.
    -->
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>Knopo</string>
    <key>CFBundleDisplayName</key>
    <string>Knopo</string>
    <key>CFBundleExecutable</key>
    <string>Knopo</string>
    <key>CFBundleIconFile</key>
    <string>$ICON_FILE</string>$ICON_NAME_ENTRY
    <key>CFBundleIdentifier</key>
    <string>com.knopo.app</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
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

# Localizations, before codesign: otherwise CodeResources seals a Resources
# directory that no longer matches and the signature breaks.
for lproj in Localization/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# Ad-hoc signature: required for arm64 binaries to launch from Finder.
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "Done: $APP"
echo "  open $APP                            # default graph: ~/Documents/Knopo"
echo "  KNOPO_GRAPH=~/notes $APP/Contents/MacOS/Knopo   # custom graph"
