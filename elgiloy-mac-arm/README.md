# cobalt tab switcher (macOS)

ctrl+tab / ctrl+shift → floating overlay lists your tabs, highlight mirrors
chrome's real active tab, release ctrl → overlay collapses. the mouse has no
effect on the overlay at all — it's click-through and keyboard-only. the panel is vertically centered and stays centered when it
grows/shrinks.

tab lists are always warm: replies land in the cache even when they arrive
after the overlay closed (fast sessions used to discard them → blank opens),
the cache is re-primed after every session, and it persists to disk
(~/Library/Caches/elgiloy-tabs.json) so the first open after a relaunch
is never blank either.

## design: chrome switches, we draw

the daemon never switches a tab and never swallows a tab keypress. chrome
performs every ctrl+tab switch natively — its own speed, its own MRU/order
settings. the daemon is a **mirror**: it watches for cycling (listen on the
event tap), shows an overlay, and polls chrome every 50ms to highlight
whatever tab chrome actually switched to. on ctrl release it hides. there is
no commit step because nothing was ever changed by us.

the only key ever intercepted (swallowed) is **esc while the overlay is
open** — and only so chrome doesn't also treat it as "stop loading".
everything else passes through untouched.

```
ctrl+shift      overlay appears, anchored on chrome's active tab — nothing
option+shift    cycles. tap tab afterwards to move the highlight.
                (cmd+shift alone does NOT open the overlay — cmd is only
                the bracket-cycle modifier.)
ctrl+tab        overlay appears AND cycles to the next tab — the first press
option+tab      is a real switch, not just "show me the list"
cmd+shift+[     same as ctrl+shift+tab: overlay appears AND cycles backwards
ctrl+shift+tab  same, but cycles backwards
cmd+shift+[     overlay appears AND cycles backwards — the first press is a
                real switch. swallowed so chrome never double-switches.
cmd+shift+]     overlay appears AND cycles forward.
[/] while open  with cmd still held, bare [ / ] keep cycling (shift can be
                released). ctrl+tab / option+tab / cmd+[ / cmd+] all drive the
                same highlight.
ctrl+tab …      keep tapping — keeps cycling, highlight follows
release ctrl    overlay collapses (chrome already settled the tab). the
and/or cmd      session can be carried by ctrl, cmd or option — it ends when
and/or option   ALL of them are up.
esc             cancel the overlay — nothing changed, chrome was never touched
w               close the SELECTED tab — keyboard path, overlay stays open;
                selection lands on the row above the closed one every time
```

## safety nets

the overlay must never get stuck on screen, no matter what:

- a watchdog timer (independent of the event tap) checks the real global
  modifier state every 100ms while the overlay is open — the moment neither
  ctrl nor cmd is actually held (or the frontmost app changed), the session
  force-ends. covers missed flagsChanged events, taps disabled by macOS,
  cmd-tab away.
- a dead tap self-revives every 2s (macOS disables taps on callback timeout).
- last resort: `killall elgiloy` — launchd restarts it within seconds,
  and the overlay dies with the process.

## files

| file | job |
|---|---|
| `tap.swift` | CGEventTap. passes everything through except esc-while-open and the bracket cycle. watches ctrl/cmd release. |
| `main.swift` | state (`open`/`tabs`/`sel`) + the 50ms mirror poll |
| `overlay.swift` | NSPanel, rows rebuilt from scratch every render (no in-place mutation) |
| `browser.swift` | apple events: list tabs / active index / close tab (by bundle id, never by name) |

## install

```
./install.sh            build, sign, bundle, register launchd agent, start
./install.sh uninstall  stop agent, remove plist + app bundle
```

what it does: builds with swiftc, signs with the `cobalt-dev` codesign identity (required — the script fails without it and explains how to create it), copies the binary to `~/.local/bin/elgiloy`, writes `~/Library/LaunchAgents/dev.cobalt.elgiloy.plist`, and bootstraps the agent (starts at login, restarts on crash).

permissions (one-time):

1. **accessibility + input monitoring** — system settings → privacy & security → accessibility → add `~/.local/bin/elgiloy`
2. **automation** — the first ctrl+tab over chromium should pop "elgiloy wants to control Chromium" → allow. if no popup ever appears (macos suppresses it for launchd-spawned agents), run the binary once in the foreground from a terminal, press ctrl+tab, allow, ctrl+C — launchd takes it from there. the grant is recorded against the binary's `cobalt-dev` signature, so it survives rebuilds.

### the stale-denial trap (read if the prompt never appears)

tcc matches permission records by **code signature**, and every binary this
repo has ever installed shares the `cobalt-dev` identity — cobalt-switcher,
cobalt-cycle, elgiloy, all of them. that means a stale **denial** left behind
by any old version shadows the new install: tccd sees "already denied, same
signature", skips the prompt entirely, and the daemon just gets silent
`-1743` errors. you will never be asked. it will never work.

signs you're in this hole: overlay appears but tabs never switch; log shows
`OSAScriptErrorNumberKey = -1743`; no elgiloy row visible in the automation
pane.

the fix, scoped to this tool only:

    tccutil reset AppleEvents dev.cobalt.elgiloy

do NOT run a bare `tccutil reset AppleEvents` — that wipes every app's
automation grants (raycast, screenshot tools, everything). `install.sh`
already runs the scoped reset on every install, so fresh installs should
never hit this trap; it's documented here for when you're debugging an
old machine.

logs: `tail -f /tmp/elgiloy.err`

## why mirror instead of intercept+commit

| | intercept+commit (v1) | mirror (this) |
|---|---|---|
| who switches tabs | daemon, on ctrl release | chrome, instantly, natively |
| first press | daemon had to pre-advance | chrome already switched |
| commit race / wrong tab | possible | impossible — nothing is committed |
| swallowed keys | all of them | esc only, and only while open |
| chrome MRU settings | had to be replicated | just… work |
