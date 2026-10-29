# cobalt new tab extension

optional. cobalt works fully without it — this just replaces the new tab
page and de-annoys youtube. load unpacked via chrome://extensions →
developer mode, or don't run it at all.

## features

**blank new tab page** (`blank.html` + `ntp.js`; gm3-styled with
hand-rolled material design 3 tokens/components — no libraries, no build)
- plain #353535 page, "New Tab" title. no tiles, no search box, no
  google logo — the stock NTP phones home for those; this kills that.
- inline SVG favicon (8-point starburst) via data URI.
- **panel**: opens via the bottom-left fab, ctrl+c; esc or scrim click
  closes. md3 switch, sliders, tonal buttons, 28px card, state layers.
- **icon color**: colour picker + hex field, favicon updates live,
  persists via chrome.storage. reset restores the default lavender.
- **photos**: one local folder picked once (File System Access API — the
  picker starts on the Desktop; the handle persists in IndexedDB. Chrome
  resets the read permission on every browser relaunch (reboot, update, quit);
  the page then re-grants it on your first click or keypress on the new tab,
  with a Reconnect button in the panel as fallback).
  the folder is rescanned every 2s (plus on tab focus), so images added or
  removed on disk show up live: each new tab shows a random photo from the
  folder, fading in over the grey (200ms delay, 500ms fade — tunable in the
  #bg transition). no images are copied or stored — nothing bloats
  chrome.storage. panel shows folder name, count, a thumbnail strip and a
  pulsing "watching for changes" indicator.
- **adjust**: brightness (25-150%) slider. photo mode applies live via css
  filter; ascii re-samples on slider release.
- **ascii art mode**: m3 switch. port of aeolian's DotImage.tsx
  (`ascii.js`): same 7x12 grid, ramp, hover-scramble + healing, full-page
  canvas (no left taper). "decode intro" switch picks the load animation:
  intro = flickering COBALT resolving top to bottom (1600ms), off = plain
  fade-in of the finished image. "mouse interactive" switch toggles the
  hover-scramble on/off — applied live (no restart; scrambled cells just
  heal, no new ones). only deltas vs aeolian: word is COBALT,
  panel bg #353535, brightness applied via ctx.filter at sample time.
- mv3 csp: no inline scripts — logic lives in `ntp.js`/`ascii.js`.

**youtube shorts blocker** (`block.js` + `hide.css`, runs at document_start)
- hides the sidebar entry and shorts shelves.
- hides grid/search results linking to /shorts/.
- redirects /shorts/ urls to the normal watch page.
- youtube renames element classes periodically; the redirect is the only
  part that cannot break.

**youtube ad blocker** (`ytads/`, fully self-contained)
- in-video ads: killed at the data layer (`ytads/net.js`, MAIN world,
  document_start) — youtube schedules ad breaks from adPlacements/adSlots
  in the player response; those keys are stripped from the baked-in page
  response and every /youtubei/v1/player + /next fetch/xhr, so the player
  never learns an ad break exists. zero-delay removal for most ads.
- backstop (`ytads/ads.js`): for whatever still reaches the player —
  mutationobserver watches the ad state and auto-clicks the skip button
  (current selector list) within a frame, re-seeks unskippable ad streams
  to their end, closes overlay ads, and drops youtube's "ad blockers
  violate tos" wall + unpauses. rare ads take seconds instead of zero.
- feed ads: css hides the ad renderers (masthead banner, ad slots,
  promoted videos, premium promos, end-screen companion, in-video overlay
  containers), plus a js sweep for anything badged "Sponsored"/"Promoted"
  that slips past a renderer rename. reliable.
- deletable as a unit: remove the ytads/ folder + its three
  content_scripts entries in the manifest (see ytads/README.md).

**popup / popunder killer** (`popblock/`, fully self-contained)
- kills the "clicking play opens a new ad tab" thing on anime/streaming
  sites. verified against anikoto.cz's actual popunder chain (nekostream →
  llvpn.com tag.min.js, an exo/iclick-style PPU kit that also runs
  anti-devtools console tricks). layers: declarativeNetRequest blocklist
  for the known kit domains (rules.json — add new ad domains there),
  iframe sandbox attrs get their `allow-popups` tokens stripped (the
  popunder usually fires from a sandboxed player iframe that content
  scripts can't enter), `window.open` is stubbed in every reachable realm
  (toString spoofed to look native — the kit probes it), script
  `form.submit()` to _blank or no-such-frame named targets is dropped (the
  kit's main bypass), any tab that still spawns closes itself instantly
  (the trick uBO Lite's prevent-popup uses — script can close
  script-opened tabs, never user-opened ones), and synthetic
  `a.target="_blank"; a.click()` popunders are blocked.
- debugging: console.clear() neutralized, rolling log at `__popblock.log`,
  and an on-page badge (bottom-right) reports armed/blocked counts so page
  console games can't hide it from you. click the badge to dump the log.
- holding ctrl/cmd while clicking lets exactly one popup through (oauth,
  share buttons); youtube + google domains are excluded so their auth flows
  are untouched. see popblock/README.md.
- deletable as a unit: remove the popblock/ folder + its content_scripts
  entry in the manifest.

**tab pin shortcut** (`pin.js`)
- chrome has no native keyboard shortcut for pinning tabs; this adds one.
- toggles pin on the active tab. default Ctrl+Shift+P (Cmd+Shift+P on mac),
  rebindable at chrome://extensions/shortcuts.

**icons** (`icons/`) — white 8-point starburst, 16/32/48/128.

## notes

- MV3 rule: this manifest has chrome_url_overrides + content_scripts, so
  it can NOT also carry a theme key — chrome would silently reject it.
  that's why the theme lives in the template-theme/ subfolder here.

## install

no install script and no system permissions — chrome loads unpacked
extensions by folder path, so there is nothing to install:

    chrome://extensions → developer mode → load unpacked → <this folder>

chrome tracks the folder by absolute path; moving/renaming the folder
requires a re-load (remove the entry, load again).
