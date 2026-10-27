# mp35n

Co-Cr-Ni-Mo — a non-magnetic, corrosion-proof cobalt alloy used where a part has to hold under load. here: Chrome's cookie key, held in a master-password vault and handed to nothing but a verified Chrome binary.

Chrome 156 asks `org.freedesktop.secrets` for "Chrome Safe Storage" and derives its cookie key from it. This daemon owns that name, serves the secret only while unlocked and only to `/opt/google/chrome/chrome` (bus PID → `/proc/pid/exe` → sha256 pin), and keeps everything else out. New cookies land as `v11`; the old public `v10` "peanuts" key cannot read them.

## install

    ./install.sh            symlink cli + 35 alias, install systemd user unit + dbus activation, start
    ./install.sh uninstall  stop service, remove unit/dbus/symlinks (vault kept)

needs python 3.8+, `dbus-python`, `PyGObject` with GTK4 + libadwaita (`gir1.2-gtk-4.0`, `gir1.2-adw-1`), `cryptography`, and a systemd user session. no root.

## commands

    35                  status
    35 unlock           ask for the master password, hold the key in memory
    35 lock             wipe it
    35 status           locked / unlocked, pin, denied-call count
    35 init             create the vault + pin the Chrome binary
    35 trust            re-pin after a Chrome update
    35 run ARGS         re-pin if needed, unlock, start Chrome, lock again
                        (the normal launch path; also what the .desktop
                        entry points to)

unlock before Chrome starts. if Chrome launches while locked it cannot read v11 cookies and drops them, and it writes new ones as v10.

## how it works

    password --scrypt--> KEK --AES-256-GCM--> 32-byte secret   (~/.config/mp35n/vault.json)
    secret --D-Bus--> Chrome --PBKDF2-SHA1(secret,"saltysalt",1)--> AES-128 key --> v11 cookies

the daemon runs as a systemd user unit, owns `org.freedesktop.secrets`, and checks every caller: bus-attested PID, `/proc/pid/exe` realpath == the pinned Chrome path, binary root-owned and not world-writable, sha256 == the pinned hash. anything else gets `AccessDenied`.

`35` talks to the daemon over a private unix socket (`~/.config/mp35n/control.sock`, mode 600): status, unlock (password), lock. the D-Bus name is the Chrome-facing interface and is locked to the pinned binary. without a TTY, the password prompt is a native GTK4 + libadwaita dialog; there are no zenity/rofi/askpass fallbacks. the dialog shows the fixed codeword `KANEKI` above the password field.

## files

    ~/.config/mp35n/vault.json    scrypt salt/nonce + AES-GCM secret (0600)
    ~/.config/mp35n/config.json   pinned Chrome path + sha256
    ~/.local/bin/mp35n, 35        symlinks into this folder
    ~/.config/systemd/user/mp35n.service
    ~/.local/share/dbus-1/services/org.freedesktop.secrets.service

## limits

stops other applications and the public peanuts key. it is not a boundary against someone who already runs code as you (they can read this source, edit the pin, or spawn the real Chrome binary), and it is not a boundary against root. the vault is only as good as scrypt + your master password.
