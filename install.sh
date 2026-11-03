#!/bin/bash
# Vigil installer: builds from source on your Mac, so you can read every line that runs.
#
#   curl -fsSL https://raw.githubusercontent.com/yehawashia/Vigil-Tracker/main/install.sh | bash
#
# Needs macOS 13+ and Apple's command line tools (it offers to install them).
# Source goes to ~/.vigil/src (override with VIGIL_SRC). The app goes to ~/Applications/Vigil.app.
set -euo pipefail

REPO="https://github.com/yehawashia/Vigil-Tracker.git"
SRC="${VIGIL_SRC:-$HOME/.vigil/src}"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Vigil is a macOS app." >&2; exit 1
fi
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MAJOR < 13 )); then
    echo "Vigil needs macOS 13 Ventura or later (you have $(sw_vers -productVersion))." >&2; exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "Apple's command line tools are required. A dialog will open; re-run this installer when it finishes."
    xcode-select --install || true
    exit 1
fi

if [[ -d "$SRC/.git" ]]; then
    echo "==> Updating $SRC"
    git -C "$SRC" pull --ff-only --quiet
else
    echo "==> Downloading Vigil to $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --quiet "$REPO" "$SRC"
fi

cd "$SRC"
chmod +x build.sh uninstall.sh
./build.sh --install

echo
echo "Done. Look for the eye icon in your menu bar, then open the dashboard → Settings to grant permissions."
