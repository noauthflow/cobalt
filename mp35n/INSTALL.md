# Installing mp35n

`install.sh` is the single entry point. It installs the CLI, the daemon, the
desktop integration, and the xdg-desktop-portal Secret backend.

## requirements

- python 3.8+
- `dbus-python` (the `dbus` Python module)
- `PyGObject` with GTK4 and libadwaita (`gir1.2-gtk-4.0`, `gir1.2-adw-1`)
- `cryptography`
- a systemd user session
- `xdg-desktop-portal`
- sudo for the binary and portal descriptor

`install.sh` checks the Python dependencies and exits if one is missing.

## quick install

    cd /path/to/cobalt/mp35n
    ./install.sh
    ./install.sh uninstall    # optional

Root steps: copy the binary to `/usr/local/lib/mp35n/` and copy
`mp35n.portal` into `/usr/share/xdg-desktop-portal/portals/`. The rest is
user-level.

## what `install.sh` does

1. **Checks dependencies.** `python3`, `cryptography`, and GTK4 +
   libadwaita must import.

2. **Creates directories.** `~/.local/bin`, the systemd user unit
   directory, the D-Bus activation directory, and `~/.config/mp35n`
   (mode 700).

3. **Installs the binary and links the CLI.** It copies the repo's `mp35n`
   to `/usr/local/lib/mp35n/mp35n` (root:root, 0755) and creates:

       ~/.local/bin/mp35n  -> /usr/local/lib/mp35n/mp35n
       ~/.local/bin/35     -> /usr/local/lib/mp35n/mp35n

   The installed copy is what runs. It is root-owned so the user cannot
   edit the daemon or client on disk. Update it by rerunning `install.sh`.

4. **Writes the systemd user unit** at
   `~/.config/systemd/user/mp35n.service`. It runs:

       ExecStart=/usr/bin/python3 -I /usr/local/lib/mp35n/mp35n daemon
       Environment=PATH=/usr/bin:/bin
       Restart=on-failure
       RestartSec=2

   The unit is sandboxed: `UMask=0077`, `NoNewPrivileges=yes`,
   `PrivateTmp=yes`, `PrivateDevices=yes`, `ProtectSystem=strict`,
   `ProtectHome=read-only`, `ReadWritePaths=-%h/.config/mp35n`,
   `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`,
   `ProtectControlGroups=yes`, `RestrictAddressFamilies=AF_UNIX`,
   `RestrictSUIDSGID=yes`, `LockPersonality=yes`.

   It uses the absolute Python interpreter with `-I` (isolated mode) and a
   fixed `PATH`, so a `python3` or module in `~/.local/bin` / user site is
   not picked up by the daemon.

5. **Writes the D-Bus activation file** at
   `~/.local/share/dbus-1/services/org.freedesktop.secrets.service`:

       [D-BUS Service]
       Name=org.freedesktop.secrets
       Exec=/usr/bin/python3 -I /usr/local/lib/mp35n/mp35n daemon

   This lets the session bus start the daemon on demand. The daemon still
   owns the name `org.freedesktop.secrets`, which is also the bus name the
   portal backend descriptor points at.

6. **Overrides the Chrome desktop entry.** If the upstream file
   `/usr/share/applications/google-chrome.desktop` exists, `install.sh`
   copies it to:

       ~/.local/share/applications/google-chrome.desktop

   and rewrites every `Exec=/opt/google/chrome/chrome` and
   `Exec=/usr/bin/google-chrome-stable` to:

       Exec=$HOME/.local/bin/35 run

   The user-level file has priority over the system file, so menus, rofi,
   and `xdg-open` launch Chrome through `35 run`, and there is still only
   one Chrome entry. Other fields, actions, `%U`, and Chrome flags are
   preserved.

   If the upstream file does not exist, it writes a minimal entry with:

       Exec=$HOME/.local/bin/35 run %U

   and the usual `MimeType` handlers.

   Caveat: the rewrite only matches those two `Exec=` strings. If upstream
   changes the command form, the copied entry may still launch Chrome
   directly. Terminal launches and direct binary launches bypass the
   wrapper regardless. `update-desktop-database` is run after writing it.

7. **Installs the portal descriptor** with sudo:

       mp35n.portal -> /usr/share/xdg-desktop-portal/portals/mp35n.portal

   The file is root-owned, mode 0644, and contains:

       [portal]
       DBusName=org.freedesktop.secrets
       Interfaces=org.freedesktop.impl.portal.Secret

   This tells `xdg-desktop-portal` that the Secret backend is the process
   owning `org.freedesktop.secrets` — mp35n.

8. **Ensures `portals.conf` points at it.** The user config is:

       ~/.config/xdg-desktop-portal/portals.conf

   If the file does not exist, `install.sh` creates it with:

       [preferred]
       org.freedesktop.impl.portal.Secret=mp35n;

   If it already has an `org.freedesktop.impl.portal.Secret=` line,
   `install.sh` rewrites that line to `mp35n;`. If it has no such line, it
   prints a warning and leaves the file alone. It does not overwrite
   `default=...`, `Access=...`, or `Notification=...` entries.

9. **Restarts `xdg-desktop-portal`.** The portal rereads the descriptor and
   `portals.conf`. Without this, Chrome can still get the old/no backend.

10. **Starts the daemon.** It runs `systemctl --user daemon-reload`,
    enables `mp35n.service`, and restarts it.

11. **Prints the installed paths** and tells you to run `35 init` (or
    `mp35n init`).

## files created or changed

    /usr/local/lib/mp35n/mp35n                  root-owned installed binary
    ~/.local/bin/mp35n                          symlink to the installed binary
    ~/.local/bin/35                             symlink to the installed binary
    ~/.config/systemd/user/mp35n.service        user unit
    ~/.local/share/dbus-1/services/org.freedesktop.secrets.service
    ~/.local/share/applications/google-chrome.desktop   Chrome -> 35 run
    ~/.config/xdg-desktop-portal/portals.conf   Secret=mp35n
    /usr/share/xdg-desktop-portal/portals/mp35n.portal  (root)
    ~/.config/mp35n/                            directory, mode 700

`install.sh` does **not** create the vault. That is `35 init`.

## after install

    ./install.sh
    35 init          # create the vault, pin Chrome
    35 unlock        # or: 35 run
    35 run           # normal Chrome launch

`35 init` prompts for a master password, generates a random 32-byte secret,
writes `vault.json`, and pins the Chrome binary. `35 run` re-pins if needed,
unlocks, launches Chrome, waits for the portal delivery, and locks again.

Check it:

    journalctl --user -u mp35n -n 20 --no-pager
    35 status

Look for:

    portal secret delivered app_id='com.google.Chrome'

If you see `portal deny app_id=...`, the portal passed an app ID outside the
Chrome set. If you see `portal request while locked`, the vault was locked
when Chrome asked.

## uninstall

    ./install.sh uninstall

This:

- stops and disables `mp35n.service`
- removes the installed binary, unit, D-Bus activation file, `mp35n` and
  `35` symlinks
- removes the user-level `google-chrome.desktop` override
- removes `/usr/share/.../mp35n.portal` with sudo
- restarts `xdg-desktop-portal`
- runs `daemon-reload` and `update-desktop-database`

The vault in `~/.config/mp35n/` is kept. Delete it manually to wipe the key.
`portals.conf` is also kept; if it still says `Secret=mp35n;` after
uninstall, point it at another backend or remove the line.

## notes

- `install.sh` is idempotent: rerun it after changing the code, after
  changing `mp35n.portal`, or after a Chrome package update that changes
  the desktop file.
- The portal descriptor is installed from the repo copy. If the repo copy
  is modified before `install.sh` runs, that modified file is installed as
  root. Run it from a trusted checkout.
- The desktop override is a copy of the upstream file at install time. It
  does not update itself when Chrome's package updates the system file;
  rerun `install.sh` to refresh it.
- The unit and D-Bus activation file embed the interpreter and
  `/usr/local/lib/mp35n/mp35n`. Moving the repo does not break the installed
  copy; rerun `install.sh` to update it from the repo.
- `35 run` is the normal launch path. A terminal `google-chrome`, a direct
  `/opt/google/chrome/chrome`, or Chrome's own relaunch can bypass it.
