# Installing mp35n

`install.sh` is the single entry point. It installs the CLI, the daemon, the
desktop integration, and the xdg-desktop-portal Secret backend.

## requirements

- python 3.8+
- `dbus-python` (the `dbus` Python module)
- `PyGObject` with GTK4 and libadwaita (`gir1.2-gtk-4.0`, `gir1.2-adw-1`)
- `cryptography`
- systemd (system manager + your user session)
- `xdg-desktop-portal`
- sudo for the binary, the system units and the portal descriptor

`install.sh` checks the Python dependencies and exits if one is missing.

## quick install

    cd /path/to/cobalt/mp35n
    ./install.sh
    ./install.sh uninstall    # optional

Root steps: copy the binary to `/usr/local/lib/mp35n/`, install the system
units into `/usr/local/lib/systemd/system/`, and copy `mp35n.portal` into
`/usr/share/xdg-desktop-portal/portals/`. The rest is user-level.

## what `install.sh` does

1. **Checks dependencies.** `python3`, `cryptography`, and GTK4 +
   libadwaita must import.

2. **Creates `~/.local/bin`.** The vault is `~/.config/35vault.json`,
   created by `35 init`. An empty `~/.config/mp35n` left from an old
   install is removed, as are the units of the removed vault service.

3. **Installs the binary and links the CLI.** It copies the repo's `mp35n`
   to `/usr/local/lib/mp35n/mp35n` (root:root, 0755) and creates:

       ~/.local/bin/mp35n  -> /usr/local/lib/mp35n/mp35n
       ~/.local/bin/35     -> /usr/local/lib/mp35n/mp35n

   The installed copy is what runs. It is root-owned so the user cannot
   edit the daemon or client on disk. Update it by rerunning `install.sh`.

4. **Removes the old user-level install**: disables the user unit and
   deletes `~/.config/systemd/user/mp35n.service`,
   `~/.local/share/dbus-1/services/org.freedesktop.secrets.service` and
   `~/.config/mp35n/control.sock`. Anything running as you could edit
   those, or the user manager's environment, and inject into the daemon.

5. **Installs root-owned system units** into
   `/usr/local/lib/systemd/system/`, generated for your user:

   - `mp35n.socket`: PID 1 creates `/run/mp35n/control.sock` (socket owned
     by you, mode 600) inside root-owned `/run/mp35n/`. A process running as
     you cannot unlink it and plant a fake daemon to collect the password.
   - `mp35n.service`: runs `/usr/bin/python3 -I
     /usr/local/lib/mp35n/mp35n daemon` as `User=<you>` with a fixed
     environment (`PATH`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` of
     your session bus). Nothing from your session or user manager
     (`environment.d`, `systemctl --user set-environment`) reaches it.
     `BindsTo=user@<uid>.service`: it starts and stops with your user
     manager, `Restart=always`.

   Hardening: `UMask=0077`, `NoNewPrivileges`, empty capability sets,
   `RestrictNamespaces`, `SystemCallFilter=@system-service ~@privileged`,
   `RestrictAddressFamilies=AF_UNIX`, `RestrictSUIDSGID`,
   `RestrictRealtime`, `LockPersonality`, `LimitCORE=0`. No
   `PrivateTmp`/`ProtectSystem`/`ProtectHome`/...: those give the daemon
   its own mount namespace, and it must share Chrome's to verify it. The
   daemon makes itself non-dumpable at start, and refuses to run unless
   it got its socket from systemd.

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

10. **Starts the daemon.** `sudo systemctl daemon-reload`, enables and
    restarts `mp35n.socket` and `mp35n.service`, waits for the daemon, then
    restarts `xdg-desktop-portal` so it sees the backend on the bus.

11. **Prints the installed paths** and tells you to run `35 init` (or
    `mp35n init`).

## files created or changed

    /usr/local/lib/mp35n/mp35n                  root-owned installed binary
    ~/.local/bin/mp35n                          symlink to the installed binary
    ~/.local/bin/35                             symlink to the installed binary
    /usr/local/lib/systemd/system/mp35n.socket  (root) control socket unit
    /usr/local/lib/systemd/system/mp35n.service (root) daemon, runs as you
    /run/mp35n/control.sock                     created by systemd at runtime
    ~/.local/share/applications/google-chrome.desktop   Chrome -> 35 run
    ~/.config/xdg-desktop-portal/portals.conf   Secret=mp35n
    /usr/share/xdg-desktop-portal/portals/mp35n.portal  (root)
    ~/.config/35vault.json                      the vault (0600, made by 35 init)

`install.sh` does **not** create the vault. That is `35 init`.

## after install

    ./install.sh
    35 init          # create the vault
    35 run           # normal Chrome launch

`35 init` prompts for a master password, generates a random 32-byte secret,
and writes `~/.config/35vault.json`. `35 run` unlocks, launches and authorizes Chrome,
waits for the portal delivery, and the vault locks itself after it.

Check it:

    journalctl -u mp35n -n 20 --no-pager
    35 status

Look for:

    portal secret delivered app_id='com.google.Chrome'

If you see `portal deny app_id=...`, the portal passed an app ID outside the
Chrome set. If you see `portal request while locked`, the vault was locked
when Chrome asked.

## uninstall

    ./install.sh uninstall

This:

- stops and disables `mp35n.service` and `mp35n.socket`
- removes the installed binary, system units, `mp35n` and `35` symlinks
- removes the user-level `google-chrome.desktop` override
- removes `/usr/share/.../mp35n.portal` with sudo
- restarts `xdg-desktop-portal`
- runs `daemon-reload` and `update-desktop-database`

The vault `~/.config/35vault.json` is kept. Delete it to wipe the key.
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
- The units embed the interpreter, `/usr/local/lib/mp35n/mp35n`, your user
  name and uid. Moving the repo does not break the installed
  copy; rerun `install.sh` to update it from the repo.
- `35 run` is the normal launch path. A terminal `google-chrome`, a direct
  `/opt/google/chrome/chrome`, or Chrome's own relaunch can bypass it.
