#!/bin/bash
# chronifer — live Downloads folder icon: custom icon with current 24h time in red
# builds main.swift, installs binary + icon asset to ~/.local/bin, registers launchd daemon
# (persistent daemon that fires exactly on each wall-clock minute boundary)
#   ./install.sh            build + install + start
#   ./install.sh uninstall  stop agent, remove plist + binary, restore default icon
set -euo pipefail
cd "$(dirname "$0")"

NAME="chronifer"
LABEL="dev.cobalt.chronifer"
BIN_LOCAL="$HOME/.local/bin/$NAME"
ASSET="$HOME/.local/bin/blackfolder.icns"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$BIN_LOCAL" "$ASSET"
  # strip the custom icon so Finder falls back to the default folder icon
  xattr -d com.apple.ResourceFork "$HOME/Downloads" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$HOME/Downloads" 2>/dev/null || true
  killall Finder 2>/dev/null || true
  echo "uninstalled: agent stopped, plist + $BIN_LOCAL removed, default icon restored"
  exit 0
fi

command -v swiftc >/dev/null || { echo "swiftc is required (xcode-select --install)"; exit 1; }
[[ -f blackfolder.icns ]] || { echo "blackfolder.icns missing from project folder"; exit 1; }

echo "building (swiftc)"
mkdir -p "$HOME/.local/bin"
# build straight to the install target — nothing lands in the repo folder
swiftc -O -o "$BIN_LOCAL" main.swift -framework AppKit
# no TCC permissions needed, ad-hoc sign is sufficient
codesign --force --sign - "$BIN_LOCAL"
cp blackfolder.icns "$ASSET"

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
echo "launchd:   $LABEL — daemon, starts at login, restarts on crash, logs: /tmp/$NAME.err"
