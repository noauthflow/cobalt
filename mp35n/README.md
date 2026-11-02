# mp35n

Co-Cr-Ni-Mo — a non-magnetic, corrosion-proof cobalt alloy used where a part
has to hold under load. here: Chrome's cookie key, held in a master-password
vault and handed to Chrome through the desktop portal's pipe.

Chrome 156 gets a per-app secret from `org.freedesktop.portal.Secret` and
derives its cookie key from it. mp35n
implements the portal's Secret backend, verifies the caller and app ID, and
writes the 32-byte secret straight into Chrome's file descriptor while the
vault is unlocked. The secret never crosses D-Bus. The old
`org.freedesktop.secrets` interface is still present, but only to refuse
sessions; it never returns the secret.

**Chrome only encrypts with the portal key when it is launched with
`--enable-features=SecretPortalKeyProviderUseForEncryption`.** Without it,
Chrome fetches the key, ignores it, and writes `v10` cookies that anyone can
decrypt with the public `"peanuts"` key. `35 run` always adds the flag. With
it, new cookies land as `v12` and cannot be read without the vault secret.
`35 status` counts cookie prefixes per profile and warns about `v10`.

See [INSTALL.md](INSTALL.md) for exactly what `install.sh` creates, and
[SECURITY.md](SECURITY.md) for the threat model.

## install

    ./install.sh            root-owned binary + user install + portal descriptor (sudo) + start
    ./install.sh uninstall  stop service, remove binary/unit/dbus/symlinks/portal descriptor

Needs python 3.8+, `dbus-python`, `PyGObject` with GTK4 + libadwaita
(`gir1.2-gtk-4.0`, `gir1.2-adw-1`), `cryptography`, `xdg-desktop-portal`, and
systemd. sudo is used for the root-owned binary, the system units and the
portal descriptor.

## commands

    35                  status
    35 lock             wipe the key
    35 status           locked / unlocked, last delivery, refusals, cookie prefixes
    35 init             create the vault
    35 run ARGS         unlock, start + authorize Chrome, deliver once, lock
                        (the only launch path that gets the key; also what
                        the .desktop entry points at)
    35 unlock           unlock without authorizing anything (testing only)

Only a Chrome started by `35 run` receives the key. Any other launch
(`google-chrome`, Chrome's own restart) is refused, falls back to `v10`,
and drops `v12` cookies it cannot decrypt. If Chrome is already running,
`35 run` just hands the URL to it without asking for the password.

The vault is a matched pair with the cookie DB: restoring `Cookies` from git
only works with the same key.

## how it works

    password --scrypt--> KEK --AES-256-GCM--> 32-byte secret   (~/.config/35vault.json)
    secret --portal fd--> Chrome (needs SecretPortalKeyProviderUseForEncryption) --> AES-256-GCM --> v12 cookies

The daemon runs as a root-owned systemd system service under your uid and writes the secret into the pipe
the portal hands it, but only if the read end of that pipe is held by
exactly the Chrome process `35 run` launched and authorized with the
one-time token from the unlock, and that process is the root-owned
`/opt/google/chrome/chrome` with an allowed command line and a clean
environment. See [SECURITY.md](SECURITY.md) for every check. The legacy
`org.freedesktop.secrets` name never returns the secret.

`35` talks to the daemon over a private unix socket
(`/run/mp35n/control.sock`, created by systemd in a root-owned directory): status, unlock (password), lock.
Without a TTY the password prompt is a native GTK4 + libadwaita dialog; there
are no zenity/rofi/askpass fallbacks. The dialog shows the fixed codeword
`KANEKI` above the password field. It is a label, not a trust boundary.

## files

    ~/.config/35vault.json        scrypt salt/nonce + AES-GCM secret (0600)
    /usr/local/lib/mp35n/mp35n    root-owned installed binary
    ~/.local/bin/mp35n, 35        symlinks to the installed binary
    /usr/local/lib/systemd/system/mp35n.{socket,service}   root-owned units
    /run/mp35n/control.sock       control socket (systemd-created)
    ~/.local/share/applications/google-chrome.desktop   -> 35 run
    /usr/share/xdg-desktop-portal/portals/mp35n.portal
    /etc/polkit-1/rules.d/50-mp35n.rules   lets the daemon freeze/thaw your session scopes
    ~/.config/xdg-desktop-portal/portals.conf
    mp35n.portal                  portal descriptor (this folder)

## limits

mp35n protects the cookie key at rest, against other users, and against
non-Chrome clients. It is not a boundary against code running as you, root,
or a kernel that allows same-user ptrace. The vault is only as good as
scrypt + your master password. `v10` cookies remain readable with the public
`"peanuts"` key, Chrome caches the key for its lifetime, and a launch while
locked destroys `v12` cookies. Launching Chrome without `35 run` (no feature
flag) silently writes new cookies as `v10`. See [SECURITY.md](SECURITY.md).
