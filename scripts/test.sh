#!/bin/zsh
# Runs the test suite. The Command Line Tools don't add the Testing.framework
# search path automatically (and its Foundation cross-import overlay fails to
# load from the CLT), hence the explicit flags.
set -e
cd "$(dirname "$0")/.."
FWK=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
# The Swift Testing runtime's interop dylib lives here and isn't on the
# default runpath under Command Line Tools.
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
# Only when the toolchain has no Testing.framework. Xcode ships one, and its
# @Test macro needs that same version.
CLT_FLAGS=()
# Without || true, set -e aborts here when no developer dir is set.
XCODE_FWK="$(xcode-select -p 2>/dev/null || true)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
if [[ ! -d "$XCODE_FWK/Testing.framework" && -d "$FWK" ]]; then
  CLT_FLAGS=(
    -Xswiftc -F$FWK
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    -Xlinker -rpath -Xlinker $FWK
    -Xlinker -rpath -Xlinker $LIB
  )
fi
# One syntax error fails a whole table, not one line, silently reverting the UI
# to its keys.
for f in Localization/**/*.(strings|stringsdict)(N); do
  plutil -lint "$f" >/dev/null || { echo "malformed: $f" >&2; exit 1; }
done

# AppKit tests share the main thread and application state. Concurrent cases
# can delay highlight checks until their animations have already finished.
# Match the app bundle's SDK linkage. Xcode 27 otherwise records the
# deployment target as the SDK and tests older AppKit/SwiftUI behavior.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
exec swift test --no-parallel "${CLT_FLAGS[@]}" \
  -Xswiftc -Xclang-linker -Xswiftc "-isysroot$SDK_PATH" "$@"
