# popblock — popup / popunder killer

kills the "every click opens a new tab" thing on anime/streaming sites.
self-contained like ytads: this folder + one `content_scripts` entry in
`../manifest.json`. to remove it:

1. delete this folder
2. remove the popblock entry from `../manifest.json`

nothing else depends on it.

## what it does

- **network blocklist** (`rules.json`, declarativeNetRequest): the known
  popunder kit domains are blocked outright — currently
  `nekostream.site`, `llvpn.com`, `dump.mewcdn.online` (anikoto.cz's chain,
  verified by tracing its loader scripts). no script load = no popunder,
  no anti-devtools console games. hit a new site? curl the page, find its
  ad-script domain, add a rule with the next id.
- **anti anti-debug** (layer 6): `console.clear()` is neutralized and an
  on-page badge (bottom-right, top frame only) reports "popblock armed" on
  load and flashes red with a blocked-count on every caught attempt —
  visible even when the page plays console games. click the badge to dump
  the log; a rolling buffer also lives at `self.__popblock.log`.
  devtools tip: the kit also loops `debugger` statements / shakes the page
  when devtools is open — press cmd+F8 (deactivate breakpoints) to stop
  that, and prefer testing with devtools closed: some kits change behavior
  when devtools is detected.

- **iframe sandbox stripping** (layer 1): on stream sites the popunder
  usually fires from a sandboxed cross-origin player iframe (`allow-popups`
  in its sandbox attribute) — and chrome injects no content scripts into
  sandboxed frames, so the js layers below never run there. instead the top
  page watches every iframe (mutation observer + initial sweep) and strips
  the `allow-popups` / `allow-popups-to-escape-sandbox` tokens from the
  sandbox. a sandboxed frame without them cannot window.open. iframes with
  no sandbox attribute are left alone.
- **opener side** (layer 2): replaces `window.open` with a stub returning a
  fake window object — the tab is never created, and the page's script keeps
  working off the fake handle (`w.location.href=...`, `w.document.write(...)`,
  `w.closed` all behave). run in the MAIN world at document_start so page
  scripts see it from the very first line. the stub is also walked into every
  reachable same-origin/about:blank child frame (native `open` returns in
  each new realm), and its `toString()` is spoofed to look native — the
  exo/iclick-style PPU kits that stream sites load (anikoto → nekostream →
  llvpn.com tag.min.js) probe exactly that.
- **form side** (layer 3): the same kits' main bypass —
  `window.open('','name')` (faked by layer 2), then a
  `form.target="name"` + script `submit()` still conjures a real tab since
  no window with that name exists. script-called
  `submit()`/`requestSubmit()` to `_blank` or to a named target with no
  matching frame are dropped, and untrusted submit events on such forms are
  canceled. real user submits (trusted events, targets pointing at actual
  frames) are untouched.
- **popup side** (layer 3, the uBO Lite `prevent-popup` trick): any tab that
  still spawns closes itself instantly at document_start. browsers allow
  script to close tabs that script opened, but never tabs the user opened —
  so typed urls, ctrl+clicks and normal links are untouched. catches
  popunders that dodge layer 2 (captured `open` reference, redirect chains).
- **synthetic anchor clicks** (layer 4): the `document.createElement("a");
  a.target="_blank"; a.click()` popunder pattern is blocked at the document
  level — only untrusted clicks are canceled, real ones pass.

## debugging

- badge bottom-right on load = script is running. no badge = not reloaded
  or excluded.
- click the badge (or read `__popblock.log`) for the event list.
- console: `[popblock] armed on ...` at info, details at debug
  (console → filter levels → enable "verbose").

## escapes

- **ctrl/cmd = let one through**: holding ctrl (⌘ on mac) while clicking
  lets exactly the next `window.open` happen. this is the door for oauth
  ("continue with google") and share popups, which otherwise look broken.
- **excluded domains**: `*.youtube.com` and `*.google.com` are excluded in
  the manifest so google/youtube auth flows never touch this. add more
  `exclude_matches` entries there if some site needs real popups.
- sites that grabbed a reference to `window.open` *before* the content
  script ran (rare — document_start is as early as it gets) can bypass
  layer 1; layer 2 still kills the spawned tab.
- about:blank popups that redirect before any document load can slip past
  layer 2 once in a while; layer 1 covers those.

## honest limits

- unsandboxed cross-origin player iframes are covered by layer 2/3, but a
  site that finds another scripting context chrome won't let us into stays
  open game.
- anything opening a tab through means other than `window.open`/anchor
  clicks (form submit to `_blank`, `navigation` api abuse) isn't handled —
  kept basic on purpose.
