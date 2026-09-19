#!/bin/bash
# smalt — menu bar strip daemon: build, sign, install to ~/.local/bin, register launchd agent
#   ./install.sh            build + install + start
#   ./install.sh uninstall  stop agent, remove plist + binary
set -euo pipefail
cd "$(dirname "$0")"

NAME="smalt"
LABEL="dev.cobalt.smalt"
BIN_LOCAL="$HOME/.local/bin/$NAME"
ASSET_DIR="$HOME/.local/share/$NAME"
SVG_ASSETS=(battery audio bluetooth mic wifi Night-Day power moon night night-off)
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$BIN_LOCAL"
  for asset in "${SVG_ASSETS[@]}"; do rm -f "$ASSET_DIR/$asset.svg"; done
  rmdir "$ASSET_DIR" 2>/dev/null || true
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
mkdir -p "$ASSET_DIR"
for asset in "${SVG_ASSETS[@]}"; do cp "icons/$asset.svg" "$ASSET_DIR/"; done
# build straight to the install target — nothing lands in the repo folder
swiftc -O -o "$BIN_LOCAL" main.swift -framework AppKit -framework QuartzCore -framework IOBluetooth -F /System/Library/PrivateFrameworks -framework CoreBrightness
codesign --force --sign "$IDENTITY" "$BIN_LOCAL"
if [[ "$IDENTITY" != "-" ]]; then echo "signed (cobalt-dev)"; fi

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

# battery click — Low Power Mode toggling needs root, exactly ONCE. this
# installs the scoped sudoers rule (only the two pmset commands — nothing
# else gets passwordless root) whenever it's missing, validated with visudo
# before it lands. no root available? skipped with a hint, install proceeds.
LPM_RULE="$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a lowpowermode 0, /usr/bin/pmset -a lowpowermode 1"
LPM_FILE=/etc/sudoers.d/smalt-lpm
# the rule file is 440 root:wheel — unreadable to this user, which is
# CORRECT. unreadable-but-present counts as installed; only a missing file
# (or a readable file without the exact rule) triggers the setup.
if [[ ! -f $LPM_FILE ]] || { [[ -r $LPM_FILE ]] && ! grep -qxF "$LPM_RULE" "$LPM_FILE"; }; then
  echo "battery click: granting passwordless Low Power Mode toggle (sudo, one-time)"
  if sudo sh -c "echo '$LPM_RULE' > /etc/sudoers.d/smalt-lpm.tmp \\
      && chmod 440 /etc/sudoers.d/smalt-lpm.tmp \\
      && visudo -cf /etc/sudoers.d/smalt-lpm.tmp >/dev/null \\
      && mv /etc/sudoers.d/smalt-lpm.tmp '$LPM_FILE'"; then
    echo "  done — battery clicks toggle instantly, no password"
  else
    echo "  skipped — enable later with: sudo ./enable-lpm.sh"
  fi
fi

echo
echo "installed: $BIN_LOCAL"
echo "launchd:   $LABEL — starts at login, restarts on crash, logs: /tmp/$NAME.err"
echo
echo "permissions: none — the reveal is a global mouse monitor, not an event tap"
echo 'battery click: toggles Low Power Mode — passwordless rule auto-installed on'
echo '  first ./install.sh (sudo ./enable-lpm.sh remove undoes it; ./enable-lpm.sh re-adds it)'
echo "try it: fullscreen an app — the strip hides; move the cursor to the top edge — it slides down"
