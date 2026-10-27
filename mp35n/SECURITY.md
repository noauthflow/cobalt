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
