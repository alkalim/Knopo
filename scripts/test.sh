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
# One syntax error fails a whole table, not one line, silently reverting the UI
# to its keys.
for f in Localization/**/*.(strings|stringsdict)(N); do
  plutil -lint "$f" >/dev/null || { echo "malformed: $f" >&2; exit 1; }
done

exec swift test \
  -Xswiftc -F$FWK \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -rpath -Xlinker $FWK \
  -Xlinker -rpath -Xlinker $LIB "$@"
