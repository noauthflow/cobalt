#!/bin/bash
# cerulean — complete display enable/disable via private SkyLight APIs
#   ./install.sh            build + install to ~/.local/bin
#   ./install.sh watch      build + install + launchd agent that keeps externals off
#   ./install.sh unwatch    remove the agent
#   ./install.sh uninstall  remove the binary (and agent)
set -euo pipefail
cd "$(dirname "$0")"

NAME="cerulean"
BIN_LOCAL="$HOME/.local/bin/$NAME"
STATE_FILE="$HOME/.cerulean_disabled"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/dev.cobalt.cerulean" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/dev.cobalt.cerulean.plist"
  if [[ -f "$STATE_FILE" ]]; then
    echo "warning: $STATE_FILE exists — a display may currently be disabled."
    echo "         Re-enable it before uninstalling: $BIN_LOCAL on-all"
  fi
  rm -f "$BIN_LOCAL"
  echo "uninstalled: $BIN_LOCAL removed"
  exit 0
fi

command -v swiftc >/dev/null || { echo "swiftc is required (xcode-select --install)"; exit 1; }

MODE="${1:-}"

if security find-identity -v -p codesigning | grep -q "cobalt-dev"; then
  IDENTITY="cobalt-dev"
else
  echo "note: no 'cobalt-dev' identity found — signing ad-hoc (fine: no TCC permissions involved)"
  IDENTITY="-"
fi

echo "building (swiftc)"
mkdir -p "$HOME/.local/bin"
# build straight to the install target — nothing lands in the repo folder
swiftc -O -o "$BIN_LOCAL" cerulean.swift
codesign --force --sign "$IDENTITY" "$BIN_LOCAL"
if [[ "$IDENTITY" != "-" ]]; then echo "signed (cobalt-dev)"; fi

if [[ "$MODE" == "watch" || "$MODE" == "unwatch" ]]; then
  PLIST="$HOME/Library/LaunchAgents/dev.cobalt.cerulean.plist"
  launchctl bootout "gui/$(id -u)/dev.cobalt.cerulean" 2>/dev/null || true
  if [[ "$MODE" == "watch" ]]; then
    cat > "$PLIST" <<PLIST_XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.cobalt.cerulean</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_LOCAL</string>
    <string>watch</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>/tmp/cerulean.log</string>
  <key>StandardErrorPath</key><string>/tmp/cerulean.log</string>
</dict>
</plist>
PLIST_XML
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || launchctl load "$PLIST"
    echo
    echo "watch agent installed & started (KeepAlive, runs at login)"
    echo "log: /tmp/cerulean.log"
    echo "remove with: $0 unwatch"
  else
    rm -f "$PLIST"
    echo
    echo "watch agent removed (currently-disabled displays stay disabled)"
  fi
  exit 0
fi

echo
echo "installed: $BIN_LOCAL"
echo
echo "usage:"
echo "  cerulean list          show main + external display IDs"
echo "  cerulean off           completely disable every external display — permanently,"
echo "                         if the watch agent is installed (survives replug/sleep/reboot)"
echo "  cerulean on            re-enable what 'off' disabled (also lifts watch enforcement)"
echo "  cerulean on-all        re-enable everything (emergency reset)"
echo "  cerulean watch         foreground watcher (normally run via the launchd agent)"
echo
echo "permanent watcher:  ./install.sh watch   (remove: ./install.sh unwatch)"
echo
echo "notes: disabled displays are remembered in $STATE_FILE"
echo "       while that file exists, 'watch' re-disables any external display that appears"
