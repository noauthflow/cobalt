#!/bin/bash
# smalt — menu bar strip daemon: build, sign, install to ~/.local/bin, register launchd agent
#   ./install.sh            build + install + start
#   ./install.sh uninstall  stop agent, remove plist + binary
set -euo pipefail
cd "$(dirname "$0")"

NAME="smalt"
LABEL="dev.cobalt.smalt"
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

# smalt needs no permissions today, but sign with the house identity when it's
# there — a stable signature means any permission smalt earns later (event
# taps, accessibility for v1 widget rehosting) survives rebuilds.
if security find-identity -v -p codesigning | grep -q "cobalt-dev"; then
  IDENTITY="cobalt-dev"
else
  echo "note: no 'cobalt-dev' identity found — signing ad-hoc (fine for v0, no permissions needed)"
  IDENTITY="-"
fi

echo "building (swiftc)"
mkdir -p "$HOME/.local/bin"
# build straight to the install target — nothing lands in the repo folder
swiftc -O -o "$BIN_LOCAL" main.swift -framework AppKit -framework QuartzCore
codesign --force --sign "$IDENTITY" "$BIN_LOCAL"
if [[ "$IDENTITY" != "-" ]]; then echo "signed (cobalt-dev)"; fi

mkdir -p "$HOME/.local/bin"
cp -f "$NAME" "$BIN_LOCAL"

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
echo "launchd:   $LABEL — starts at login, restarts on crash, logs: /tmp/$NAME.err"
echo
echo "permissions: none — the reveal is a global mouse monitor, not an event tap"
echo "try it: fullscreen an app — the strip hides; move the cursor to the top edge — it slides down"
