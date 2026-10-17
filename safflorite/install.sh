#!/bin/bash
# safflorite — hold ⌘⇧Space: translucent 24h clock pill at the bottom of every screen
# builds main.swift, installs binary to ~/.local/bin, registers launchd agent
# (persistent agent so the hotkey is always live; overlay shown while held)
#   ./install.sh            build + install + start
#   ./install.sh uninstall  stop agent, remove plist + binary
set -euo pipefail
cd "$(dirname "$0")"

NAME="safflorite"
LABEL="dev.cobalt.safflorite"
BIN_LOCAL="$HOME/.local/bin/$NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$BIN_LOCAL"
  echo "uninstalled: agent stopped, plist + $BIN_LOCAL removed"
  exit 0
fi

command -v swiftc >/dev/null || { echo "swiftc is required (xcode-select --install)"; exit 1; }

echo "building (swiftc)"
mkdir -p "$HOME/.local/bin"
# build straight to the install target — nothing lands in the repo folder
swiftc -O -o "$BIN_LOCAL" main.swift -framework AppKit
# no TCC permissions needed (Carbon hotkey), ad-hoc sign is sufficient
codesign --force --sign - "$BIN_LOCAL"

launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN_LOCAL</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/$NAME.err</string>
</dict></plist>
EOF
launchctl bootstrap "$GUI" "$PLIST"

echo
echo "installed: $BIN_LOCAL"
echo "launchd:   $LABEL — agent, starts at login, restarts on crash, logs: /tmp/$NAME.err"
echo "usage:     hold ⌘⇧Space to show the clock pill, release to hide"
