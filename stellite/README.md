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
- **photos**: drag-and-drop grid (or + tile -> file picker) with
  per-photo remove. stored as data urls (unlimitedStorage). each new
  tab shows a random photo fading in over the grey (200ms delay,
  500ms fade — tunable in the #bg transition).
- **adjust**: brightness (25-150%) + blur (0-20px) sliders. photo mode
  applies live via css filter; ascii re-samples on slider release.
- **ascii art mode**: m3 switch. port of aeolian's DotImage.tsx
  (`ascii.js`): same 7x12 grid, ramp, hover-scramble + healing, full-page
  canvas (no left taper). "decode intro" switch picks the load animation:
  intro = flickering COBALT resolving top to bottom (1600ms), off = plain
  fade-in of the finished image. only deltas vs aeolian: word is COBALT,
  panel bg #353535, adjustments applied via ctx.filter at sample time.
- mv3 csp: no inline scripts — logic lives in `ntp.js`/`ascii.js`.

**youtube shorts blocker** (`block.js` + `hide.css`, runs at document_start)
- hides the sidebar entry and shorts shelves.
- hides grid/search results linking to /shorts/.
- redirects /shorts/ urls to the normal watch page.
- youtube renames element classes periodically; the redirect is the only
  part that cannot break.

**tab pin shortcut** (`pin.js`)
- chrome has no native keyboard shortcut for pinning tabs; this adds one.
- toggles pin on the active tab. default Ctrl+Shift+P (Cmd+Shift+P on mac),
  rebindable at chrome://extensions/shortcuts.

**icons** (`icons/`) — white 8-point starburst, 16/32/48/128.

## notes

- MV3 rule: this manifest has chrome_url_overrides + content_scripts, so
  it can NOT also carry a theme key — chrome would silently reject it.
  that's why the theme lives in a separate folder (cobalt-theme/).

## install

no install script and no system permissions — chrome loads unpacked
extensions by folder path, so there is nothing to install:

    chrome://extensions → developer mode → load unpacked → <this folder>

chrome tracks the folder by absolute path; moving/renaming the folder
requires a re-load (remove the entry, load again).
