# mp35n security notes

The real weakness is not the crypto, it is the trust boundary: mp35n is a
user-level keyring, so anything running as your user can beat it. I
demonstrated one concrete path — `~/.config/mp35n/config.json` (the Chrome
pin) is user-writable, so a same-user process can repoint it at any
root-owned binary (e.g. `/usr/bin/python3`), call the daemon while the vault
is unlocked, and receive the 32-byte secret; every `v11` cookie then
decrypts. The same ownership problem applies to `~/.local/bin/mp35n`, the
systemd user unit, and the D-Bus activation file: malware can rewrite the
client, capture the master password at unlock, or replace the control
socket. Root is worse — root can read the daemon's memory, ptrace it, or
keylog the password, so no user-level design survives root. The vault is
also only as strong as scrypt + your password (~0.1 s per guess at the
current parameters), so weak or dictionary passwords are offline-crackable.
Finally, `v10` cookies are still readable with the public "peanuts" key, and
Chrome caches the key for its own lifetime: locking does not revoke it from
a running browser, and a browser started while locked drops all `v11`
cookies. Bottom line: mp35n protects against other keyring clients and
at-rest theft while locked. It is not a boundary against same-user code
execution or root.

## convenience

Unlocking is a manual step, and the failure is silent and destructive: if
Chrome starts while the vault is locked it cannot decrypt `v11` cookies, so
it drops them and starts writing new ones as `v10`. The only recovery is to
restore `google-chrome/Default/Cookies` from the git repo and relaunch with
the vault unlocked — and that only works if the vault is the same one those
cookies were encrypted with. Keeping the cookie snapshot in git current is
also manual and annoying: you have to quit Chrome, copy/commit the DB, and
remember that `Cookies` and `vault.json` are a pair.

Chrome updates add a second, sneakier path to the same failure. The daemon
pins Chrome by sha256; after an update the hash no longer matches and every
call is denied — even when the vault is unlocked and everything was done
right. Chrome then falls back to `v10`, and every `v11` cookie is lost
again, this time without any locked-launch mistake to blame. `35 trust`
prevents it, but only if it runs before the first launch after the update,
and nobody remembers that. A launch wrapper therefore has to close this
case itself: check the pinned hash against the binary about to run, and
re-pin if it changed, *before* unlocking — otherwise the unlock is wasted
on a launch that is going to be denied anyway. Auto-repin is safe here
because the hash being pinned is the exact root-owned binary the user just
chose to launch: it is the same trust decision `35 trust` makes, just one
that cannot be forgotten. One residual hole is not worth engineering
around: if Chrome restarts itself mid-session after an in-place update,
the binary changed under a running browser. The `v11` key is already
delivered at that point and this does not drop cookies; the next launch
simply goes through the wrapper and re-pins.

A launch guard would fix both failures — e.g. a wrapper that checks the
pinned hash, refuses to start Chrome while the vault is locked (or
re-pins and unlocks as above), and only then execs Chrome. The trade-off
is friction: it has to intercept whatever
launches Chrome (desktop entry, keybind, `google-chrome` in a terminal) and
a hardcoded wrapper is easy to bypass, or to find annoying on the day you
just want a browser. Middle ground: set Chrome's startup to **New Tab**
rather than restoring tabs (a restored tab can show a cached logged-out
page even when the cookies are fine), and make `35 unlock` the first thing
you run after login. A `35 run`-style guard is worth it only if the wrapper
is the normal way Chrome is launched, not a thing you fight with `pkill`
and a terminal.

The bigger reason for a real run command is not the locked-launch or
stale-pin bugs, it is the unlocked window: while the vault is open, any process can start the
pinned Chrome with a copied profile and ask *Chrome* to decrypt. So the
unlock should exist only for the few seconds Chrome needs to fetch the key.
The right shape is a `35 run` that re-pins Chrome if the binary hash
changed, unlocks (prompting if needed), starts Chrome, waits until the
daemon confirms the key was delivered to the verified Chrome PID, and
locks immediately — then exits, leaving Chrome running with its cached key.
The re-pin has to come before the unlock so a post-update launch can never
spend an unlock on a denied secret; with it, `35 run` also fixes the
update-loses-cookies failure for free, which is a bigger everyday win than
the lock-tightening itself. The guard must be launchable from anywhere,
not just a terminal — a .desktop entry, rofi, or a niri spawn bind — so
the password prompt is native GTK when there is no TTY (no zenity, rofi,
or askpass fallbacks) and messages go out as desktop notifications. The
prompt shows the fixed codeword `KANEKI`, which is a label, not a
same-user boundary. Same command, same behavior,
whatever launches it. If delivery is never confirmed but Chrome is still
running, the vault stays unlocked and says so: that beats silently
pushing Chrome to `v10`, which is the exact disaster this exists to
prevent. A daemon-side note records every successful delivery, so the
confirmation is real, not assumed. That turns a session-long exposure into a
sub-second one. It needs to be the normal launch path (desktop entry and
keybind, not just a terminal), and it is still only a guard: calling the
binary directly bypasses it. But it is the difference between "unlocked all
day" and "unlocked for one second per browser launch", which is the part
that actually matters against a generic Chrome-aware stealer.
