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

A launch guard would fix the silent-drop failure — e.g. a wrapper that
checks `35 status` and refuses to start Chrome (or prompts to unlock) unless
the vault is open. The trade-off is friction: it has to intercept whatever
launches Chrome (desktop entry, keybind, `google-chrome` in a terminal) and
a hardcoded wrapper is easy to bypass, or to find annoying on the day you
just want a browser. Middle ground: set Chrome's startup to **New Tab**
rather than restoring tabs (a restored tab can show a cached logged-out
page even when the cookies are fine), and make `35 unlock` the first thing
you run after login. A `35 run`-style guard is worth it only if the wrapper
is the normal way Chrome is launched, not a thing you fight with `pkill`
and a terminal.

The bigger reason for a real run command is not the locked-launch bug, it is
the unlocked window: while the vault is open, any process can start the
pinned Chrome with a copied profile and ask *Chrome* to decrypt. So the
unlock should exist only for the few seconds Chrome needs to fetch the key.
The right shape is a `35 run` that unlocks (prompting if needed), starts
Chrome, waits until the daemon confirms the key was delivered to the
verified Chrome PID, and locks immediately — then exits, leaving Chrome
running with its cached key. That turns a session-long exposure into a
sub-second one. It needs to be the normal launch path (desktop entry and
keybind, not just a terminal), and it is still only a guard: calling the
binary directly bypasses it. But it is the difference between "unlocked all
day" and "unlocked for one second per browser launch", which is the part
that actually matters against a generic Chrome-aware stealer.
