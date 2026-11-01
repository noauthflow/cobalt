#!/bin/bash
# mp35n — install the Chrome cookie keyring CLI + systemd user unit
#   ./install.sh            install root-owned binary + symlinks + unit + dbus activation + portal descriptor, start
#   ./install.sh uninstall  stop/disable service, remove binary + unit + symlinks + portal descriptor
set -euo pipefail
cd "$(dirname "$0")"

NAME="mp35n"
BIN="$HOME/.local/bin/$NAME"
ALIAS="$HOME/.local/bin/35"
UNIT="$HOME/.config/systemd/user/$NAME.service"
DBUS="$HOME/.local/share/dbus-1/services/org.freedesktop.secrets.service"
DESKTOP="$HOME/.local/share/applications/google-chrome.desktop"
OLD_DESKTOP="$HOME/.local/share/applications/mp35n-chrome.desktop"
PORTAL_DEST="/usr/share/xdg-desktop-portal/portals/mp35n.portal"
PORTAL_CONF="$HOME/.config/xdg-desktop-portal/portals.conf"
LIBDIR="/usr/local/lib/mp35n"
LIB="$LIBDIR/mp35n"

if [[ "${1:-}" == "uninstall" ]]; then
  systemctl --user disable --now "$NAME.service" 2>/dev/null || true
  rm -f "$UNIT" "$DBUS" "$ALIAS" "$BIN" "$DESKTOP" "$OLD_DESKTOP"
  sudo rm -f "$LIB"
  sudo rmdir "$LIBDIR" 2>/dev/null || true
  sudo rm -f "$PORTAL_DEST"
  systemctl --user restart xdg-desktop-portal.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  echo "uninstalled: code, unit, dbus activation, $ALIAS, $BIN, $DESKTOP, portal descriptor removed"
  echo "note: vault kept in ~/.config/mp35n/ — delete it manually to wipe the key"
  exit 0
fi

PYTHON="$(command -v python3)" || { echo "python3 is required"; exit 1; }
"$PYTHON" -I -c "import cryptography" 2>/dev/null || {
  echo "python3 'cryptography' is required (pip install cryptography)"; exit 1; }
"$PYTHON" -I -c "import gi; gi.require_version('Gtk', '4.0'); gi.require_version('Adw', '1'); from gi.repository import Gtk, Adw" 2>/dev/null || {
  echo "PyGObject with GTK4 + libadwaita is required (gir1.2-gtk-4.0, gir1.2-adw-1)"; exit 1; }

sudo install -D -m 0755 -o root -g root "$PWD/$NAME" "$LIB"

mkdir -p "$HOME/.local/bin" "$(dirname "$UNIT")" "$(dirname "$DBUS")" \
         "$HOME/.config/mp35n"
chmod 700 "$HOME/.config/mp35n"

# the running copy is root-owned; ~/.local/bin holds symlinks to it
ln -sfn "$LIB" "$BIN"
ln -sfn "$LIB" "$ALIAS"

cat > "$UNIT" <<EOF
[Unit]
Description=mp35n master-password keyring
After=dbus-broker.service dbus.service

[Service]
ExecStart=$PYTHON -I $LIB daemon
Environment=PATH=/usr/bin:/bin
Restart=on-failure
RestartSec=2
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=-%h/.config/mp35n
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX
RestrictSUIDSGID=yes
LockPersonality=yes

[Install]
WantedBy=default.target
EOF

cat > "$DBUS" <<EOF
[D-BUS Service]
Name=org.freedesktop.secrets
Exec=$PYTHON -I $LIB daemon
EOF

# desktop entry: overrides the upstream google-chrome.desktop (same file
# name, higher priority dir), so every launch path — rofi, menus, xdg-open,
# mime associations — goes through `35 run` and there is only ONE chrome
# entry in any launcher.
UPSTREAM_DESKTOP=/usr/share/applications/google-chrome.desktop
if [[ -f "$UPSTREAM_DESKTOP" ]]; then
  sed -e "s|Exec=/opt/google/chrome/chrome|Exec=$HOME/.local/bin/35 run|g" \
      -e "s|Exec=/usr/bin/google-chrome-stable|Exec=$HOME/.local/bin/35 run|g" \
      "$UPSTREAM_DESKTOP" > "$DESKTOP"
else
  cat > "$DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Google Chrome (mp35n)
Exec=$HOME/.local/bin/35 run %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml_xml;x-scheme-handler/http;x-scheme-handler/https;
EOF
fi
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

sudo install -D -m 0644 -o root -g root "$PWD/mp35n.portal" "$PORTAL_DEST"
mkdir -p "$(dirname "$PORTAL_CONF")"
if [[ ! -f "$PORTAL_CONF" ]]; then
  printf '[preferred]\norg.freedesktop.impl.portal.Secret=mp35n;\n' > "$PORTAL_CONF"
elif grep -q '^org\.freedesktop\.impl\.portal\.Secret=' "$PORTAL_CONF"; then
  sed -i 's|^org\.freedesktop\.impl\.portal\.Secret=.*|org.freedesktop.impl.portal.Secret=mp35n;|' "$PORTAL_CONF"
else
  echo "warning: set 'org.freedesktop.impl.portal.Secret=mp35n;' in $PORTAL_CONF"
fi
systemctl --user restart xdg-desktop-portal.service 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now "$NAME.service"
systemctl --user restart "$NAME.service"

echo "installed: $BIN -> $LIB"
echo "alias:     $ALIAS -> $LIB"
echo "binary:    $LIB (root-owned)"
echo "unit:      $UNIT"
echo "dbus:      $DBUS"
echo "desktop:   $DESKTOP (menu/rofi entry -> 35 run)"
echo "portal:    $PORTAL_DEST"
echo
echo "next: mp35n init   (or 35 init) to create the vault"
