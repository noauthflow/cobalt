#!/bin/bash
# mp35n — install the Chrome cookie keyring CLI + root-owned systemd system units
#   ./install.sh            install root-owned binary + units + portal descriptor, user symlinks + desktop entry, start
#   ./install.sh uninstall  stop/disable units, remove binary + units + symlinks + portal descriptor
set -euo pipefail
cd "$(dirname "$0")"

NAME="mp35n"
BIN="$HOME/.local/bin/$NAME"
ALIAS="$HOME/.local/bin/35"
# root-owned system units: PID 1 runs the daemon as you with a fixed
# environment, and creates the control socket in root-owned /run/mp35n/
SYSUNITDIR="/usr/local/lib/systemd/system"
SYSUNIT="$SYSUNITDIR/$NAME.service"
SYSSOCK="$SYSUNITDIR/$NAME.socket"
# left over from the removed vault service; removed on install
VAULTUNIT="$SYSUNITDIR/$NAME-vault.service"
VAULTSOCK="$SYSUNITDIR/$NAME-vault.socket"
# left over from the old user-unit install; removed on install
OLD_UNIT="$HOME/.config/systemd/user/$NAME.service"
OLD_DBUS="$HOME/.local/share/dbus-1/services/org.freedesktop.secrets.service"
OLD_SOCK="$HOME/.config/mp35n/control.sock"
USER_NAME="$(id -un)"
USER_GROUP="$(id -gn)"
USER_UID="$(id -u)"
DESKTOP="$HOME/.local/share/applications/google-chrome.desktop"
OLD_DESKTOP="$HOME/.local/share/applications/mp35n-chrome.desktop"
PORTAL_DEST="/usr/share/xdg-desktop-portal/portals/mp35n.portal"
PORTAL_CONF="$HOME/.config/xdg-desktop-portal/portals.conf"
LIBDIR="/usr/local/lib/mp35n"
LIB="$LIBDIR/mp35n"
# lets the daemon (running as you) freeze/thaw your login session scopes
# during a key delivery; your user@ cgroups it freezes directly
POLKIT_RULE="/etc/polkit-1/rules.d/50-mp35n.rules"

if [[ "${1:-}" == "uninstall" ]]; then
  sudo systemctl disable --now "$NAME.service" "$NAME.socket" \
    "$NAME-vault.service" "$NAME-vault.socket" 2>/dev/null || true
  sudo rm -f "$SYSUNIT" "$SYSSOCK" "$VAULTUNIT" "$VAULTSOCK"
  sudo systemctl daemon-reload
  systemctl --user disable --now "$NAME.service" 2>/dev/null || true
  rm -f "$OLD_UNIT" "$OLD_DBUS" "$OLD_SOCK" "$ALIAS" "$BIN" "$DESKTOP" "$OLD_DESKTOP"
  sudo rm -f "$LIB"
  sudo rmdir "$LIBDIR" 2>/dev/null || true
  sudo rm -f "$PORTAL_DEST" "$POLKIT_RULE"
  systemctl --user restart xdg-desktop-portal.service 2>/dev/null || true
  systemctl --user daemon-reload 2>/dev/null || true
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  echo "uninstalled: code, system units, $ALIAS, $BIN, $DESKTOP, portal descriptor removed"
  echo "note: vault kept at ~/.config/35vault.json — delete it to wipe the key"
  exit 0
fi

PYTHON="$(command -v python3)" || { echo "python3 is required"; exit 1; }
"$PYTHON" -I -c "import cryptography" 2>/dev/null || {
  echo "python3 'cryptography' is required (pip install cryptography)"; exit 1; }
"$PYTHON" -I -c "import gi; gi.require_version('Gtk', '4.0'); gi.require_version('Adw', '1'); from gi.repository import Gtk, Adw" 2>/dev/null || {
  echo "PyGObject with GTK4 + libadwaita is required (gir1.2-gtk-4.0, gir1.2-adw-1)"; exit 1; }

sudo install -D -m 0755 -o root -g root "$PWD/$NAME" "$LIB"

mkdir -p "$HOME/.local/bin"

# the running copy is root-owned; ~/.local/bin holds symlinks to it
ln -sfn "$LIB" "$BIN"
ln -sfn "$LIB" "$ALIAS"

# migrate off the old user unit: it ran under your user manager, whose
# environment (and unit file) any process running as you can change
systemctl --user disable --now "$NAME.service" 2>/dev/null || true
rm -f "$OLD_UNIT" "$OLD_DBUS" "$OLD_SOCK"
rmdir "$HOME/.config/mp35n" 2>/dev/null || true   # only if empty (old vault kept)
systemctl --user daemon-reload 2>/dev/null || true

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

cat > "$TMPD/$NAME.socket" <<EOF
[Unit]
Description=mp35n control socket for $USER_NAME

[Socket]
ListenStream=/run/mp35n/control.sock
SocketUser=$USER_NAME
SocketGroup=$USER_GROUP
SocketMode=0600
DirectoryMode=0755
RemoveOnStop=yes

[Install]
WantedBy=sockets.target
EOF

cat > "$TMPD/$NAME.service" <<EOF
[Unit]
Description=mp35n master-password keyring for $USER_NAME
Requires=$NAME.socket
After=$NAME.socket user@$USER_UID.service
BindsTo=user@$USER_UID.service
StartLimitIntervalSec=0

[Service]
User=$USER_NAME
Group=$USER_GROUP
ExecStart=$PYTHON -I $LIB daemon
# fixed environment: nothing from your session or user manager leaks in
Environment=PATH=/usr/bin:/bin
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus
Restart=always
RestartSec=2
# No PrivateTmp/ProtectSystem/ProtectHome/PrivateDevices/ProtectKernel*:
# each gives the daemon its own mount namespace, and it must share Chrome's
# to verify it (verify_chrome_process compares namespaces).
UMask=0077
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged
LimitCORE=0

[Install]
WantedBy=user@$USER_UID.service
EOF

# remove the vault service from an earlier install
sudo systemctl disable --now "$NAME-vault.service" "$NAME-vault.socket" 2>/dev/null || true
sudo rm -f "$VAULTUNIT" "$VAULTSOCK"

# Login session scopes (TTY/ssh: session-N.scope) are root-owned cgroups, so
# the daemon freezes them through systemd. Only session scopes, only for
# $USER_NAME. Not limited by verb: you can already end your own sessions
# (loginctl terminate-session), so stop/kill here gives nothing new.
cat > "$TMPD/50-mp35n.rules" <<EOF
// mp35n: freeze/thaw login session scopes during a cookie-key delivery
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.user == "$USER_NAME" &&
        /^session-[0-9]+\\.scope\$/.test(action.lookup("unit") || "")) {
        return polkit.Result.YES;
    }
});
EOF
sudo install -D -m 0644 -o root -g root "$TMPD/50-mp35n.rules" "$POLKIT_RULE"

sudo install -D -m 0644 -o root -g root "$TMPD/$NAME.socket" "$SYSSOCK"
sudo install -D -m 0644 -o root -g root "$TMPD/$NAME.service" "$SYSUNIT"

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

sudo systemctl daemon-reload
sudo systemctl enable "$NAME.socket" "$NAME.service"
sudo systemctl restart "$NAME.socket"
sudo systemctl restart "$NAME.service"
for _ in $(seq 1 50); do
  rc=0; "$LIB" status >/dev/null 2>&1 || rc=$?
  [[ $rc -le 1 ]] && break   # 0 unlocked, 1 locked, 2 no daemon yet
  sleep 0.2
done
# the portal must see the daemon on the bus
systemctl --user restart xdg-desktop-portal.service 2>/dev/null || true

echo "installed: $BIN -> $LIB"
echo "alias:     $ALIAS -> $LIB"
echo "binary:    $LIB (root-owned)"
echo "units:     $SYSSOCK, $SYSUNIT (root-owned, runs as $USER_NAME)"
echo "vault:     ~/.config/35vault.json"
echo "socket:    /run/mp35n/control.sock"
echo "desktop:   $DESKTOP (menu/rofi entry -> 35 run)"
echo "portal:    $PORTAL_DEST"
echo "polkit:    $POLKIT_RULE (freeze/thaw session scopes during delivery)"
echo
echo "next: 35 init   to create the vault"
