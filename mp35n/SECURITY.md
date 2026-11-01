# mp35n security notes

The key lives in a master-password vault (scrypt + AES-256-GCM) at
`~/.config/35vault.json`. The daemon writes the key once per unlock into the portal pipe of
the Chrome that `35 run` launched. It never crosses D-Bus.

## open

1. **Password capture.** `35` runs in your session, so `LD_PRELOAD` (via
   environment.d, a `.desktop` override or shell rc) hooks it and records the
   master password. Tested. Password + `35vault.json` = key. The password
   is also replayable: malware can run `35 run --password-stdin` whenever it
   wants and retry the pipe read (2) until it wins.
   Fix: make unlock non-replayable, e.g. a hardware key touch (FIDO2
   hmac-secret) per launch, so a capture gives nothing to reuse.

2. **Pipe read.** Any same-uid process can open `/proc/<chrome>/fd/N` (or the
   portal's end) and read the key, then write it back unnoticed. It evades
   the reader scan by going non-dumpable or opening after the scan.
   Fix: refuse when an unknown non-dumpable process with your uid exists
   (exempt `(sd-pam)` by pid/parent, not name); rescan after the write.
   Real fix: SELinux `chrome_t` + `staff_u` login.

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
