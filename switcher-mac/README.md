# cobalt tab switcher (macOS)

ctrl+tab → floating overlay lists your tabs, highlight mirrors chrome's real
active tab, release ctrl → overlay collapses. hover a row + esc closes that tab.
the panel is vertically centered and stays centered when it grows/shrinks.

tab lists are always warm: replies land in the cache even when they arrive
after the overlay closed (fast sessions used to discard them → blank opens),
the cache is re-primed after every session, and it persists to disk
(~/Library/Caches/cobalt-switcher-tabs.json) so the first open after a relaunch
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
ctrl+tab        overlay appears AND cycles to the next tab — the first press
                is a real switch, not just "show me the list"
ctrl+shift+tab  same, but cycles backwards
ctrl+tab …      keep tapping — keeps cycling, highlight follows
release ctrl    overlay collapses (chrome already settled the tab)
esc             over a row → close that tab; not hovering → cancel overlay
```

## safety nets

the overlay must never get stuck on screen, no matter what:

- a watchdog timer (independent of the event tap) checks the real global
  modifier state every 100ms while the overlay is open — the moment ctrl
  isn't actually held (or the frontmost app changed), the session force-ends.
  covers missed flagsChanged events, taps disabled by macOS, cmd-tab away.
- a dead tap self-revives every 2s (macOS disables taps on callback timeout).
- last resort: `killall cobalt-switcher` — launchd restarts it within seconds,
  and the overlay dies with the process.

## files

| file | job |
|---|---|
| `tap.swift` | CGEventTap. passes everything through except esc-while-open. watches ctrl release. |
| `main.swift` | state (`open`/`tabs`/`sel`/`hover`) + the 50ms mirror poll |
| `overlay.swift` | NSPanel, rows rebuilt from scratch every render (no in-place mutation) |
| `browser.swift` | apple events: list tabs / active index / close tab (by bundle id, never by name) |

## install

```
./install.sh
```

one-time permissions: accessibility (re-grant after every rebuild — the grant
is tied to the binary's ad-hoc signature), plus one automation prompt on the
first ctrl+tab.

logs: `tail -f /tmp/cobalt-switcher.err`

## why mirror instead of intercept+commit

| | intercept+commit (v1) | mirror (this) |
|---|---|---|
| who switches tabs | daemon, on ctrl release | chrome, instantly, natively |
| first press | daemon had to pre-advance | chrome already switched |
| commit race / wrong tab | possible | impossible — nothing is committed |
| swallowed keys | all of them | esc only, and only while open |
| chrome MRU settings | had to be replicated | just… work |
