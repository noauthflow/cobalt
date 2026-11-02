# mp35n security notes

The key lives in a master-password vault (scrypt + AES-256-GCM) at
`~/.config/35vault.json`. The daemon writes the key once per unlock into the portal pipe of
the Chrome that `35 run` launched. It never crosses D-Bus.

## open

1. **Password capture.** `35` runs in your session, so `LD_PRELOAD` (via
   environment.d, a `.desktop` override or shell rc) hooks it and records the
   master password. Tested. Password + `35vault.json` = key. The password
   is also replayable: malware can run `35 run --password-stdin` whenever it
   wants.
   Fix: make unlock non-replayable, e.g. a hardware key touch (FIDO2
   hmac-secret) per launch, so a capture gives nothing to reuse.

## closed

- **Pipe read.** Any same-uid process can open `/proc/<chrome>/fd/N` (or
  the portal's or bus's copy of the pipe) and read the key while it sits
  there. This needs no knowledge of mp35n. Now every delivery freezes all
  your other processes (cgroup v2 freezer) before the key is written:
  every cgroup under `user@UID.service` directly, login session scopes
  through systemd (`FreezeUnit`, allowed by
  `/etc/polkit-1/rules.d/50-mp35n.rules`). Only Chrome's two scopes
  (`mp35n-chrome-*.scope` from `35 run`, `app-com.google.Chrome-<pid>.scope`
  Chrome moves itself into), the portal frontend and the session bus keep
  running. Then every running process of your uid is audited: it must be
  Chrome or its descendant (or Chrome's crashpad handler), or the root-owned
  portal / bus binary with no code-loading environment; anything else that
  is not frozen refuses the delivery. The key is written, and only after
  Chrome has read every byte (`FIONREAD` = 0) is everything thawed. A
  frozen process that opened the pipe earlier finds it empty. `35 status`
  shows how long others were frozen and warns if Chrome did not read within
  5 s or a process appeared mid-delivery. A crash thaws on restart; a
  watchdog thread thaws after 10 s regardless.
  Left: the portal and bus are trusted while running (their binaries and
  environment are checked, not their memory). Root is out of scope.
  SELinux `chrome_t` + `staff_u` would close it without the freeze.

## nice to keep in mind

- **Daemon can be killed.** It runs as you; malware can stop it and block
  deliveries, but gets no key.
- **Offline guessing.** `35vault.json` is copyable; scrypt (N=2^15, r=8,
  p=1) only slows guessing. Use a long random master password.
- **Profile tampering.** An extension with `cookies` permission gets cookies
  legitimately. Closed only while the policy has `"*": blocked`
  (`35 status` shows it; `apply-policy.sh --dev` drops it). Flags in
  `Local State` are not covered.
- **Forced v10.** A `lock` during launch, or starting Chrome directly, makes
  Chrome drop v12 cookies (you're logged out) and write unprotected v10.
- **Window control.** Anything running as you can drive Chrome's UI into
  DevTools and read cookies.
- **Bus-name squatting.** Whoever holds `org.freedesktop.secrets` answers
  Chrome's key request. The daemon then refuses unlocks, alerts, shows the
  holder in `35 status`, and takes the name back when it is freed. A Chrome
  started without `35 run` meanwhile gets a key the squatter chose.
- **Network lock.** Proxy env vars are stripped and refused; the managed
  policy (`apply-policy.sh`) sets `ProxyMode: direct`,
  `CAPlatformIntegrationEnabled: false`, `DnsOverHttpsMode: off`.
  `35 status` shows whether it is in place.
- **Root.** Root can read the key from Chrome's memory.
- **No rekey.** One stolen key decrypts every v12 cookie, past and future,
  until `35 init --force`.
