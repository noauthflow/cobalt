# mp35n security notes

mp35n keeps Chrome's cookie key in a master-password vault (scrypt +
AES-256-GCM) and writes it once per unlock into the portal pipe of the one
Chrome process `35 run` launched and authorized. Before writing, the daemon
checks that the caller is the root-owned portal, that the pipe's read end is
held only by the authorized PID, and that this PID is the root-owned
`/opt/google/chrome/chrome` with an allowed argv, a clean env, no tracer and
the same namespaces. The key never crosses D-Bus.

## open problems

1. **Key theft through Chrome's pipe.** Any same-uid process can open
   `/proc/<chrome>/fd/N` and read the key out of the pipe. `ptrace_scope=2`
   does not stop this: Yama only gates ptrace attach and `/proc/<pid>/mem`,
   not the fd open. The daemon's reader scan is the only defence, and it can
   be bypassed:
   - **Hidden readers.** Any process can call `prctl(PR_SET_DUMPABLE, 0)`.
     Its fd table becomes unreadable, and the daemon only logs it as
     "uninspectable" and delivers anyway.
   - **Scan race.** `pipe_readers()` walks `/proc` once and the daemon writes
     afterwards. A reader that opens the pipe after its own PID was scanned
     is never seen.

   The secret never rotates, so one theft decrypts every v12 cookie, past and
   future, until `35 init --force`. Real fix: an SELinux `chrome_t` domain
   plus a confined login (`staff_u`). As `unconfined_t`, nothing can be
   denied.

2. **Password capture.** `~/.local/bin/35`, the `.desktop` override,
   `environment.d`, shell rc files and the user unit are all user-writable.
   Malware can show a fake prompt (`KANEKI` is public) or preload code into
   the `35` client, then decrypt `vault.json` itself.

3. **Offline guessing.** Any same-uid process can copy `vault.json`. scrypt
   `N=2^15, r=8, p=1` only slows guessing; a weak master password falls.

4. **Profile tampering.** Malware can edit `~/.config/google-chrome`, e.g.
   add an extension with the `cookies` permission, and Chrome then reads the
   cookies for it legitimately. This is only closed while the root-owned
   policy carries the `"*": blocked` rule (`35 status` shows it);
   `apply-policy.sh --dev` drops it while you load unpacked folders.

5. **Root and Chrome's memory.** Chrome holds the key while it runs.
   `ptrace_scope=2` keeps other non-root processes out of its memory; root
   can read it.

## not leaks, but losses

Any same-uid process can make Chrome start without the key: send `lock` to
`control.sock` during a launch, or kill Chrome and relaunch it directly.
Chrome then deletes the v12 cookies it cannot decrypt (you get logged out)
and writes new ones as v10. Existing v12 cookies are never re-encrypted as
v10.

## bottom line

The key is safe at rest and from other users. Against malware running as
you, the weak points are the pipe race (1) and the password prompt (2).
