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
exec swift test \
  -Xswiftc -F$FWK \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -rpath -Xlinker $FWK \
  -Xlinker -rpath -Xlinker $LIB "$@"
