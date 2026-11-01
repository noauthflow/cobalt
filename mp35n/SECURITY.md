# mp35n security notes

mp35n keeps Chrome's cookie key in a master-password vault (scrypt +
AES-256-GCM) and writes it once per unlock into the portal pipe of the one
Chrome process `35 run` launched and authorized. The key never crosses
D-Bus.

Everything below was tested on this machine (2026-11-01), not inferred.
Tests that would have needed the real master password or root were left
undone and are marked.

## fixed in the 2026-11-01 pass

- **Fake daemon stealing the password.** The `35` client used to connect to
  `~/.config/mp35n/control.sock`, which any same-uid process could unlink
  and replace. A stand-in daemon captured a password typed into the real
  prompt. The socket is now `/run/mp35n/control.sock`, created by systemd
  inside root-owned `/run/mp35n/` (`mp35n.socket`). Tested: `rm`, `mv` and
  `touch` in that directory all fail with `Permission denied`.
- **Code injection into the daemon.** The daemon was a *user* unit: its unit
  file and the user manager's environment were yours, so
  `systemctl --user set-environment` (or `LD_PRELOAD`) reached it. Tested:
  the old daemon picked up an injected variable. It is now a root-owned
  system unit (`/usr/local/lib/systemd/system/mp35n.service`) run by PID 1
  as your uid with a fixed environment, empty capability sets, seccomp and
  `NoNewPrivs`, and it refuses to run unless systemd handed it the socket.
  It also makes itself non-dumpable, so its fd table is unreadable. Tested:
  the daemon comes up on first connect, owns the bus name, hides its fd
  table, exits if started any other way, and still verifies Chrome and the
  portal through `/proc` while non-dumpable.
- **Wrong D-Bus design.** The original code returned the key in clear text
  in `GetSecrets` replies; any bus monitor could read it. The pipe design
  removes it from the bus; the Secret service interface only refuses.
- **Wrong claims.** Earlier notes said only setuid helpers can be
  non-dumpable, and that `lock` on the control socket was "a nuisance, not a
  leak". Both were wrong and are corrected below.

## still open

1. **Key theft through Chrome's pipe.** Any same-uid process can open
   `/proc/<chrome>/fd/N` and read the key. `ptrace_scope=2` does not stop
   it: Yama gates ptrace attach and `/proc/<pid>/mem` only. The daemon's
   reader scan is the only defence, and it can be bypassed two ways:
   - **Hidden readers.** Any process can call `prctl(PR_SET_DUMPABLE, 0)`;
     its fd table becomes unreadable and the daemon only logs it as
     "uninspectable" and delivers anyway.
   - **Scan race.** `pipe_readers()` walks `/proc` once and the daemon writes
     afterwards; a reader that opens the pipe after its own PID was scanned
     is never seen.

   Tested: the fd open works under `ptrace_scope=2`, and the `prctl` call
   hides the fd table. Not tested: a full win against real Chrome.
   The secret never rotates, so one theft decrypts every v12 cookie, past
   and future, until `35 init --force`.
   Fixes, cheapest first: refuse delivery when a hidden process has all four
   uids equal to yours; rescan after the write and alert if a new reader
   appeared; add `35 rekey`. Real fix: SELinux `chrome_t` plus a confined
   login (`staff_u`) - see "SELinux" below.

2. **Client injection (password capture).** The `35` client runs in your
   session, so the `.desktop` override, `environment.d` and shell rc files
   can add `LD_PRELOAD`. Tested: a `.so` hooked into the root-owned `35`
   captured the password it sent to the daemon. Root-owning the binary does
   not help; the environment comes from the session. Fix: the daemon shows
   the prompt itself and hands back only the launch token, which is useless
   without a verified Chrome.

3. **Daemon can be killed.** It runs as you, so it can be stopped; for
   `RestartSec=2` malware could hold the bus name and block deliveries. It
   cannot obtain the key this way.

4. **Offline guessing.** Any same-uid process can copy `vault.json`. scrypt
   `N=2^15, r=8, p=1` only slows guessing; a weak master password falls.
   Use a long random password.

5. **Profile tampering.** Editing `~/.config/google-chrome` (e.g. adding an
   extension with the `cookies` permission) makes Chrome hand over cookies
   legitimately. Closed only while the root-owned policy carries the
   `"*": blocked` rule; `35 status` shows whether it does, and
   `apply-policy.sh --dev` drops it while you load unpacked folders.

6. **Root and Chrome's memory.** Chrome holds the key while it runs.
   `ptrace_scope=2` keeps other non-root processes out; root can read it.

## not leaks, but losses

Any same-uid process can make Chrome start without the key: send `lock` to
the control socket during a launch, or kill Chrome and relaunch it directly.
Chrome deletes the v12 cookies it cannot decrypt (you get logged out) and
writes new ones as v10. Existing v12 cookies are never re-encrypted as v10.
Tested: a locked-vault launch writes v10, decryptable with the public
"peanuts" key.

## SELinux (only for the pipe problem)

Running Chrome from an execute-only binary (`chmod 0711`) makes Chrome
non-dumpable, which blocks the fd open. Tested: a second process could list
Chrome's fds with a readable binary and got `EACCES` with a 0711 one; Chrome
then needs its setuid sandbox helper. The daemon would lose its view of
Chrome, so it would need `CAP_SYS_PTRACE` in a system unit - a near-root
process. A `chrome_t` domain is cleaner: deny other domains `file read` on
it. It requires confining the whole login (`staff_u`), since as
`unconfined_t` nothing can be denied, plus small policies for the daemon
and the portal, and upkeep. Not started.

## bottom line

At rest and against other users the key is safe. In order of what is worth
doing next: a long master password (4), keep the extension policy locked
(5), the client prompt moved into the daemon (2), then the pipe fixes (1).
