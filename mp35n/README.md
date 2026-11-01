# mp35n

Co-Cr-Ni-Mo — a non-magnetic, corrosion-proof cobalt alloy used where a part
has to hold under load. here: Chrome's cookie key, held in a master-password
vault and handed to Chrome through the desktop portal's pipe.

Chrome 156 gets a per-app secret from `org.freedesktop.portal.Secret` and
derives its cookie key from it with PBKDF2(secret, `"saltysalt"`). mp35n
implements the portal's Secret backend, verifies the caller and app ID, and
writes the 32-byte secret straight into Chrome's file descriptor while the
vault is unlocked. The secret never crosses D-Bus. The old
`org.freedesktop.secrets` interface is still present, but only to refuse
sessions; it never returns the secret. New cookies land as `v11`; the old
public `v10` `"peanuts"` key cannot read them.

See [INSTALL.md](INSTALL.md) for exactly what `install.sh` creates, and
[SECURITY.md](SECURITY.md) for the threat model.

## install

    ./install.sh            root-owned binary + user install + portal descriptor (sudo) + start
    ./install.sh uninstall  stop service, remove binary/unit/dbus/symlinks/portal descriptor

Needs python 3.8+, `dbus-python`, `PyGObject` with GTK4 + libadwaita
(`gir1.2-gtk-4.0`, `gir1.2-adw-1`), `cryptography`, `xdg-desktop-portal`, and
a systemd user session. sudo is used for the root-owned binary and the
portal descriptor.

## commands

    35                  status
    35 unlock           ask for the master password, hold the key in memory
    35 lock             wipe it
    35 status           locked / unlocked, pin, last portal delivery, denied calls
    35 init             create the vault + pin the Chrome binary
    35 trust            re-pin after a Chrome update
    35 run ARGS         re-pin if needed, unlock, start Chrome, lock again
                        (the normal launch path; also what the .desktop entry
                        and the `35` alias point at)

Unlock before Chrome starts. If Chrome starts while locked, the portal
backend returns a failure and Chrome falls back to `v10`; existing `v11`
cookies are lost. `35 run` is the normal path because it unlocks first and
locks as soon as the portal delivery is confirmed.

The vault is a matched pair with the cookie DB: restoring `Cookies` from git
only works with the same `vault.json`.

## how it works

    password --scrypt--> KEK --AES-256-GCM--> 32-byte secret   (~/.config/mp35n/vault.json)
    secret --portal fd--> Chrome --PBKDF2-SHA1(secret,"saltysalt",1)--> AES-128 key --> v11 cookies

The daemon runs as a systemd user unit and writes the secret into the file
descriptor the portal hands it. It verifies that the caller is the real
`xdg-desktop-portal` process (name owner + `/proc/pid/exe`) and that the
portal passed a Chrome app ID. The legacy D-Bus name still verifies callers
against the pinned Chrome binary, but its session methods refuse and it
returns no secret.

`35` talks to the daemon over a private unix socket
(`~/.config/mp35n/control.sock`, mode 600): status, unlock (password), lock.
Without a TTY the password prompt is a native GTK4 + libadwaita dialog; there
are no zenity/rofi/askpass fallbacks. The dialog shows the fixed codeword
`KANEKI` above the password field. It is a label, not a trust boundary.

## files

    ~/.config/mp35n/vault.json    scrypt salt/nonce + AES-GCM secret (0600)
    ~/.config/mp35n/config.json   pinned Chrome path + sha256
    /usr/local/lib/mp35n/mp35n    root-owned installed binary
    ~/.local/bin/mp35n, 35        symlinks to the installed binary
    ~/.config/systemd/user/mp35n.service
    ~/.local/share/dbus-1/services/org.freedesktop.secrets.service
    ~/.local/share/applications/google-chrome.desktop   -> 35 run
    /usr/share/xdg-desktop-portal/portals/mp35n.portal
    ~/.config/xdg-desktop-portal/portals.conf
    mp35n.portal                  portal descriptor (this folder)

## limits

mp35n protects the cookie key at rest, against other users, and against
non-Chrome clients. It is not a boundary against code running as you, root,
or a kernel that allows same-user ptrace. The vault is only as good as
scrypt + your master password. `v10` cookies remain readable with the public
`"peanuts"` key, Chrome caches the key for its lifetime, and a launch while
locked destroys `v11` cookies. See [SECURITY.md](SECURITY.md).
