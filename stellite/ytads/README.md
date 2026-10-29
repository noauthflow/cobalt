# ytads — youtube ad blocker

everything for ad blocking lives in this folder + three `content_scripts`
entries in `../manifest.json`. to remove the ad blocker entirely:

1. delete this folder
2. remove the three `ytads/*` `content_scripts` entries in `../manifest.json`

nothing else (shorts blocker, ntp, pin shortcut) depends on it.

## what it does

- `net.js` (MAIN world, document_start): kills ads at the data layer.
  youtube schedules in-video ads from the player response — a JSON blob
  with `adPlacements` / `adSlots` describing every ad break. this strips
  those keys (plus `playerAds`, `adBreaks`) so the player never learns an
  ad break exists: nothing gets stitched, nothing to skip, zero delay.
  covers the response baked into the page html (property trap on
  `ytInitialPlayerResponse` — the page assigns it via `var`, and an
  existing global binding wins over the var declaration, so the assignment
  routes through the trap) and every `/youtubei/v1/player` + `/next`
  response fetched during spa navigation (fetch + xhr patches, scrubbed
  before the page reads them). runs before youtube's own scripts, which is
  why it needs document_start + MAIN world.
- `hide.css`: home/search feed ads, masthead banner, promo banners,
  watch-page ad column, end-screen companion, in-video overlay/display ad
  containers. uses `:has()` so the whole feed item disappears, not just
  the ad inside it.
- `ads.js` (isolated world, all frames): mop-up for whatever still reaches
  the player. feed sweep for anything badged "Sponsored"/"Promoted"
  (badge text is the stable signal, rAF-throttled), plus in-video:
  MutationObserver on `#movie_player` for ~same-frame reaction when the
  ad-showing class lands, clicks the skip button instantly (selector list
  includes the current `ytp-skip-ad-button`), re-seeks the ad stream to
  its end if there's no skip button (and re-seeks if youtube restores the
  position), and drops youtube's "ad blockers violate tos" enforcement
  dialog + scrim, unpausing the video. a 250ms interval backstops the
  observer in case the player element gets swapped mid-flight.

## honest limits

- feed ads: ~100% (css + badge fallback), degrades gracefully.
- in-video ads: mostly gone entirely via net.js (the player never sees an
  ad break). whatever slips through is handled by ads.js in ~0-5s instead
  of the full ad. server-side-stitched ad experiments (ad markers baked
  into the stream manifest itself) can still show — no data-layer trick
  reaches those; expect rare, not never.
- the tos-wall removal may not survive every a/b variant youtube ships;
  if the wall ever wins, the video stays paused behind the dialog.
