#!/bin/bash
# Runs the unit tests. Works with Xcode or with only Apple's command line tools
# (which ship Swift Testing outside the default search paths).
set -euo pipefail
cd "$(dirname "$0")"
CLT=/Library/Developer/CommandLineTools/Library/Developer
if xcrun --find xcodebuild >/dev/null 2>&1 && [ "$(xcode-select -p)" != "/Library/Developer/CommandLineTools" ]; then
    exec swift test "$@"
fi
exec swift test -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
    -Xlinker -F -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
