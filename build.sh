#!/bin/bash
# Builds Vigil.app (menu-bar app + bundled MCP server).
#
#   ./build.sh            build into ./build/Vigil.app
#   ./build.sh --install  build, copy to ~/Applications, start at login (and relaunch if force-quit), open it
#   ./build.sh --run      build and open from ./build
#   ./build.sh --screenshots  build and regenerate docs/screenshots from sample data
#   ./build.sh --zip      build and package build/Vigil-macOS.zip (UNIVERSAL=1 for arm64 + x86_64)
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Apple's command line tools are needed. Installing them now; re-run ./build.sh when it finishes."
    xcode-select --install || true
    exit 1
fi

# UNIVERSAL=1 ./build.sh builds for both Apple silicon and Intel (used for releases).
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

echo "==> Compiling (release)…"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/Vigil.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Vigil" "$APP/Contents/MacOS/Vigil"
cp "$BIN/VigilMCP" "$APP/Contents/MacOS/vigil-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -d Resources/AppIcon.iconset ]; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing (ad-hoc, hardened runtime)"
codesign --force --sign - --timestamp=none --options runtime --identifier dev.vigil.vigil-mcp "$APP/Contents/MacOS/vigil-mcp"
codesign --force --sign - --timestamp=none --options runtime --identifier dev.vigil.Vigil \
    --entitlements Resources/Vigil.entitlements "$APP"
codesign --verify --strict "$APP" && echo "    signature OK"

echo "==> Built $(pwd)/$APP"

case "${1:-}" in
    --install)
        DEST="$HOME/Applications/Vigil.app"
        AGENT="$HOME/Library/LaunchAgents/dev.vigil.Vigil.plist"
        launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
        pkill -x Vigil 2>/dev/null || true
        sleep 1
        mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
        rm -rf "$DEST"
        cp -R "$APP" "$DEST"

        # Run 24/7: start at login and restart within seconds whenever it stops.
        # (Quitting from Vigil's menu unloads this agent until the next login.)
        cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>dev.vigil.Vigil</string>
    <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/Vigil</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
        launchctl bootstrap "gui/$(id -u)" "$AGENT"
        echo "==> Installed to $DEST and running 24/7 (LaunchAgent dev.vigil.Vigil)."
        echo
        echo "Connect Claude Code:   claude mcp add --scope user vigil -- \"$DEST/Contents/MacOS/vigil-mcp\""
        echo "Connect Claude Desktop: Vigil → Dashboard → Agents (MCP) → Add to Claude Desktop"
        ;;
    --screenshots)
        # Renders the real UI with generated sample data (none of your own activity) into docs/screenshots.
        "$APP/Contents/MacOS/Vigil" --demo-screenshots "$(pwd)/docs/screenshots"
        ;;
    --zip)
        ditto -c -k --keepParent "$APP" "build/Vigil-macOS.zip"
        echo "==> Packaged build/Vigil-macOS.zip"
        ;;
    --run)
        pkill -x Vigil 2>/dev/null || true
        open "$APP"
        ;;
esac
