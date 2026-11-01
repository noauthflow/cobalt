# mp35n security notes

mp35n keeps Chrome's cookie key in a master-password vault and hands it to
exactly one verified Chrome process per unlock. It protects the key at rest
and against other processes asking for it. It is not a boundary against
code that can capture your master password or that runs as root.

## how the key reaches Chrome

    35 run ──password──► daemon: unlock, return one-time launch token
    35 run ──spawn──► Chrome pid X  (clean argv + env)
    35 run ──authorize(token, X)──► daemon: verify X, remember X
    Chrome: pipe() → (r, w); RetrieveSecret(w) ──D-Bus──► portal ──► daemon
    daemon: who holds r?  must be exactly {X}; X still verified
    daemon: write(w, key); lock
    Chrome: read(r) → key → AES-256-GCM → v12 cookies

The D-Bus messages carry only a file-descriptor index; the descriptor
itself travels as `SCM_RIGHTS` ancillary data on the bus socket, and the
32 key bytes go through the kernel pipe buffer. A bus monitor sees the call,
the app ID, and at most a copy of the *write* end. It never sees the key.

## what is verified before the key is written

- **The caller is the portal**: owns `org.freedesktop.portal.Desktop`, runs
  in `xdg-desktop-portal.service`, executable is root-owned
  `/usr/libexec/xdg-desktop-portal`.
- **The app ID is a Chrome ID**: weak by itself (un-sandboxed apps
  self-register it via `org.freedesktop.host.portal.Registry`), so it is
  not relied on.
- **A launch was authorized**: only the client that typed the password gets
  the launch token, and only that token can authorize one PID.
- **The pipe belongs to that PID**: every process on the system that holds
  the read end of the pipe is found via `/proc/*/fd` + `fdinfo`. It must be
  exactly the authorized Chrome. Spoofed requests (malware's own pipe) and
  snoopers (malware that opened Chrome's pipe through `/proc/X/fd/N`) are
  refused.
- **The PID is real, clean Chrome**:
  - `/proc/X/exe` is `/opt/google/chrome/chrome`, and that path and all its
    parents are root-owned, not symlinks, not group/world-writable. The
    running inode matches the file on disk. No user-writable pin: the path
    is baked into the root-owned mp35n.
  - Same mount, user and pid namespace as the daemon; not chrooted.
  - `TracerPid` 0; all uids are yours.
  - Command line: only allowed flags (`--incognito`, `--new-window`,
    `--profile-directory=`, `--ozone-platform=`, ...) plus URLs. Refused:
    `--user-data-dir`, `--remote-debugging-*`, `--load-extension`,
    `--*-cmd-prefix`, `--proxy-server`, `--headless`, and anything unknown.
  - Environment: no `LD_*`, `GTK_MODULES`, `GIO_*` module paths, `QT_*`
    plugin paths, `NSS_*`, `SSLKEYLOGFILE`, Vulkan/EGL loader overrides,
    `CHROME_CONFIG_HOME`; `HOME`/`XDG_CONFIG_HOME` point at your real profile.
    `35 run` scrubs these before launching.
- **One key per unlock**: after one delivery the daemon wipes the key.

If Chrome itself is refused, Chrome falls back to `v10` for new cookies and
drops `v12` cookies it cannot decrypt; `35 run` notifies you. A foreign
request during the window is refused and reported, and Chrome still gets
its key.

## the daemon sandbox

The unit uses only hardening that needs no namespace: `NoNewPrivileges`,
`RestrictNamespaces`, `SystemCallFilter=@system-service ~@privileged`,
`RestrictAddressFamilies=AF_UNIX`, `LockPersonality`, `RestrictRealtime`,
`RestrictSUIDSGID`, `LimitCORE=0`, `UMask=0077`.

`PrivateTmp`, `ProtectSystem`, `ProtectHome`, `PrivateDevices`,
`ProtectKernel*` and `ProtectControlGroups` are deliberately absent: in a
*user* unit each implies a private user namespace, and from inside it the
kernel denies `/proc/<pid>/exe`, `fd/`, `environ` of other processes
(`EACCES`). With them the daemon cannot verify anything. That is the bug
that once made every portal request fail ("cannot stat portal binary").

## what it does not protect against

- **Capturing your master password.** `~/.local/bin/35` (symlink), the
  `.desktop` override, `~/.config/environment.d`, shell rc files and the
  systemd user unit are all user-writable. Malware running as you can put
  a fake prompt in front of you (the `KANEKI` codeword is public and
  proves nothing) or preload code into the `35` client, then decrypt
  `vault.json` itself. Watch for unexpected password prompts.
- **Tampering with the profile.** Malware can edit
  `~/.config/google-chrome/Default` (e.g. install an extension with the
  `cookies` permission). Chrome then reads your cookies for it, legitimately.
  Root-owned Chrome policy (`/etc/opt/chrome/policies/managed/`, e.g.
  `ExtensionInstallBlocklist: ["*"]` + an allowlist) closes most of this.
- **A hidden snooper winning a race.** `/proc/X/fd/N` can be opened by any
  same-uid process; `ptrace_scope=2` does not prevent it (it only restricts
  ptrace attach and `/proc/X/mem`). mp35n sees such snoopers and refuses,
  except for processes that made themselves non-dumpable (their fd tables
  are unreadable). On a normal system the only such processes are setuid
  helpers (`(sd-pam)`, `fusermount3`); they are logged on every delivery.
  Such a snooper would also have to open Chrome's pipe in the milliseconds
  between creation and delivery and out-read Chrome.
- **Chrome's memory.** Chrome holds the key while it runs.
  `ptrace_scope=2` stops non-root processes from reading it; root can.
- **Direct launches.** `google-chrome` or `/opt/google/chrome/chrome`
  without `35 run` gets no key (no authorization) and writes `v10`. Chrome's
  own restart (update relaunch, `chrome://restart`) is a new, unauthorized
  process and drops `v12` cookies. Quit and use `35 run` instead.
- **Offline guessing.** `vault.json` is scrypt `N=2^15, r=8, p=1` +
  AES-256-GCM. A weak master password is crackable from a copy of the file;
  do not commit it anywhere.
- **The control socket** trusts your uid: any process as you can lock the
  vault or read status (a nuisance, not a leak; it cannot authorize without
  the token).
- **Root wins.**

## bottom line

A process that merely runs as you cannot get the key: it is not the
authorized Chrome, it cannot fake being it, it cannot launch a debuggable or
injected Chrome that passes, and it cannot quietly read Chrome's pipe. What
remains is the human step: protect the password prompt, and keep
`vault.json` and the cookie DB out of git.
