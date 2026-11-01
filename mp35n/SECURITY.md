# mp35n security notes

mp35n is a user-level vault for Chrome's cookie key. It protects the key at
rest and keeps it away from ordinary D-Bus traffic. It is not a boundary
against code running as you, root, or a kernel that lets another process
read your memory.

## what it protects

- The 32-byte key is encrypted at rest under your master password
  (`scrypt` + AES-256-GCM). Stealing `vault.json` alone does not reveal it.
- Other users cannot read the vault or the daemon's memory.
- Non-Chrome clients cannot get the key through mp35n's bus interfaces.
  The portal backend verifies that the caller owns
  `org.freedesktop.portal.Desktop`, that its executable is the root-owned
  `xdg-desktop-portal`, and that the portal passed a Chrome app ID
  (`com.google.Chrome`, `google-chrome`, `google-chrome-stable`, or
  `chrome`).
- The legacy `org.freedesktop.secrets` interface is present but
  `OpenSession` always fails and `GetSecret`/`GetSecrets` are gone. No D-Bus
  method returns the key.
- The portal path writes the key into Chrome's file descriptor, so the
  secret is not in a D-Bus message body. A bus monitor sees the
  `RetrieveSecret` call, the app ID, and a FIFO fd; it does not see
  plaintext or ciphertext.

## what it does not protect

Same-user code can beat a user-level keyring. In particular:

- **The pin is user-writable.** `~/.config/mp35n/config.json` can be
  repointed at another root-owned binary; `35 run` will silently re-pin it
  and launch it. The daemon's legacy D-Bus methods then trust that binary.
- **The client and unit are user-writable.** `~/.local/bin/35`, this source
  tree, the systemd user unit, and the D-Bus activation file can be
  rewritten. Malware can capture the master password at unlock or replace
  the control socket.
- **The control socket trusts the uid.** `~/.config/mp35n/control.sock` is
  mode 600, but it only checks `SO_PEERCRED` uid. Any process as you can
  lock the vault, spam unlock attempts, or read status.
- **The portal config is user-writable.** `portals.conf` decides which
  backend handles `org.freedesktop.impl.portal.Secret`. Malware can point it
  at another backend, remove mp35n, or cause a downgrade. That does not
  decrypt old `v11` cookies without the old key, but new cookies could be
  written under a key the attacker knows.
- **`install.sh` is user-writable and uses sudo** for the portal
  descriptor. If it or `mp35n.portal` is modified before you run it, you
  install the modified file as root. Run the install from a trusted
  checkout.
- **The installed portal descriptor is root-owned, but the source is not.**
  The `.portal` file in `/usr/share` is the trusted copy; the repo copy is
  what `install.sh` installs.
- **Memory and at-rest copies.** The daemon holds the key in Python
  memory while unlocked. Core dumps, swap/hibernation, and Chrome's cached
  key are outside the vault. `ptrace_scope=2` and encrypted swap help, but
  are not part of mp35n.
- **A fake Chrome while unlocked.** Anything running as you can launch the
  real Chrome binary with a copied profile and ask for the key. The portal
  app ID is the only gate; `35 run` narrows the window but cannot stop a
  direct launch.
- **A direct launch bypasses the wrapper.** The desktop entry points at
  `35 run`, but a terminal, `pkill`/relaunch, or Chrome's own restart can
  bypass it. A locked launch makes Chrome fall back to `v10`.
- **Chrome caches the key for its lifetime.** Locking the vault does not
  revoke it from a running browser.
- **`v10` cookies are public.** They are readable with the `"peanuts"`
  key. mp35n only helps when Chrome is writing `v11`.
- **Offline guessing.** `scrypt` is `N=2^15, r=8, p=1` (about 80 ms and
  32 MiB per guess here). A weak or dictionary master password is
  crackable from `vault.json`. There is no key stretching beyond that and
  no password-change command; reinit generates a new secret and loses the
  old cookies.
- **Root.** Root can read the daemon's memory, ptrace it, keylog the
  password, replace the binary, or edit any of the above. Root wins.

## portal-specific notes

The portal frontend is the identity authority. It passes an app ID to the
backend; mp35n accepts only Chrome IDs. For an un-sandboxed Chrome the
portal reported `com.google.Chrome`. If a Chrome update changes the app ID,
the backend returns failure and Chrome falls back to `v10`; check
`journalctl --user -u mp35n` for `portal deny app_id=...`.

`35 status` shows the last portal delivery time, not proof that the current
Chrome launch succeeded. The reliable signals are:

    journalctl --user -u mp35n -n 20 --no-pager
    journalctl --user -u xdg-desktop-portal -n 20 --no-pager
    35 status

Look for `portal secret delivered app_id='com.google.Chrome'`. If you see
`portal request while locked` or `portal deny app_id=...`, Chrome did not
get the key from mp35n.

The portal fd is a FIFO write end. A D-Bus monitor sees the fd number and
inode, not the secret. A same-user process with ptrace or `/proc/<pid>/fd`
access is a different boundary; `kernel.yama.ptrace_scope=2` blocks
non-root ptrace and is recommended.

## the run guard

`35 run` re-pins Chrome if the binary hash changed, unlocks if needed,
launches Chrome, waits up to 20 seconds for a portal delivery, then locks.
The re-pin happens before the unlock so a post-update launch does not waste
an unlock. If delivery is not confirmed and Chrome is still running, the
vault stays unlocked and says so; locking would silently push Chrome to
`v10`. That trade-off is deliberate.

The guard only works if it is the normal launch path. The desktop entry
override points at it; terminal launches and direct binary launches do not.
The desktop override is a copy of the upstream file with the `Exec=` paths
rewritten; if upstream changes its `Exec=` form, the copy may not match and
the wrapper can be bypassed.

## bottom line

mp35n is at-rest protection, plus a short unlocked window, plus an fd-based
delivery that keeps the key off the bus. It is not a sandbox. If you need a
real boundary, run Chrome under a different uid, a VM, or a sandbox with its
own portal identity.
