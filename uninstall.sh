#!/bin/bash
# Removes Vigil. Your tracked data is kept unless you pass --purge.
#
#   ./uninstall.sh           remove the app and the always-on service
#   ./uninstall.sh --purge   also delete ~/Library/Application Support/Vigil (all tracked data)
set -euo pipefail

AGENT="$HOME/Library/LaunchAgents/dev.vigil.Vigil.plist"
launchctl bootout "gui/$(id -u)/dev.vigil.Vigil" 2>/dev/null || true
rm -f "$AGENT"
pkill -x Vigil 2>/dev/null || true
rm -rf "$HOME/Applications/Vigil.app" "/Applications/Vigil.app" 2>/dev/null || true
echo "==> Removed Vigil.app and its background service."

CLAUDE_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if [[ -f "$CLAUDE_CFG" ]] && grep -q '"vigil"' "$CLAUDE_CFG"; then
    echo "    Note: remove the \"vigil\" entry from $CLAUDE_CFG to disconnect Claude Desktop."
fi
if command -v claude >/dev/null 2>&1; then
    claude mcp remove --scope user vigil >/dev/null 2>&1 && echo "    Disconnected from Claude Code." || true
fi

if [[ "${1:-}" == "--purge" ]]; then
    rm -rf "$HOME/Library/Application Support/Vigil"
    echo "==> Deleted all tracked data."
else
    echo "    Your data is still in ~/Library/Application Support/Vigil (run with --purge to delete it)."
fi
