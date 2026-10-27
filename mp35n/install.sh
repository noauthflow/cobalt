#!/bin/bash
# mp35n — install the Chrome cookie keyring CLI + systemd user unit
#   ./install.sh            install symlinks + unit + dbus activation, start
#   ./install.sh uninstall  stop/disable service, remove unit + symlinks
set -euo pipefail
cd "$(dirname "$0")"

NAME="mp35n"
BIN="$HOME/.local/bin/$NAME"
ALIAS="$HOME/.local/bin/35"
UNIT="$HOME/.config/systemd/user/$NAME.service"
DBUS="$HOME/.local/share/dbus-1/services/org.freedesktop.secrets.service"

if [[ "${1:-}" == "uninstall" ]]; then
  systemctl --user disable --now "$NAME.service" 2>/dev/null || true
  rm -f "$UNIT" "$DBUS" "$ALIAS" "$BIN"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "uninstalled: unit, dbus activation, $ALIAS, $BIN removed"
  echo "note: vault kept in ~/.config/mp35n/ — delete it manually to wipe the key"
  exit 0
fi

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
python3 -c "import cryptography" 2>/dev/null || {
  echo "python3 'cryptography' is required (pip install cryptography)"; exit 1; }

chmod +x "$PWD/$NAME"
mkdir -p "$HOME/.local/bin" "$(dirname "$UNIT")" "$(dirname "$DBUS")"

# source of truth stays in the repo; ~/.local/bin holds symlinks
ln -sfn "$PWD/$NAME" "$BIN"
ln -sfn "$PWD/$NAME" "$ALIAS"

cat > "$UNIT" <<EOF
[Unit]
Description=mp35n master-password keyring
After=dbus-broker.service dbus.service

[Service]
ExecStart=$PWD/$NAME daemon
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF

cat > "$DBUS" <<EOF
[D-BUS Service]
Name=org.freedesktop.secrets
Exec=$PWD/$NAME daemon
EOF

systemctl --user daemon-reload
systemctl --user enable --now "$NAME.service"
systemctl --user restart "$NAME.service"

echo "installed: $BIN -> $PWD/$NAME"
echo "alias:     $ALIAS -> $PWD/$NAME"
echo "unit:      $UNIT"
echo "dbus:      $DBUS"
echo
echo "next: mp35n init   (or 35 init) to create the vault"
