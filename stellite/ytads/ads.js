// ytads — youtube ad blocker, in-video + feed sweep.
// paired with hide.css in this folder; net.js (MAIN world) strips ads from
// the player response at the data layer, so most ads never exist at all.
// this file is the mop-up for whatever still reaches the player.
// see ./README.md.

// ── feed sweep ──
// feed items that slip past the css selectors: anything badged
// "Sponsored" / "Promoted" (youtube renames ad renderers often, the
// badge text is the stable signal). rAF-throttled — youtube mutates a lot.
let sweepQueued = false;
function queueSweep() {
  if (sweepQueued) return;
  sweepQueued = true;
  requestAnimationFrame(() => { sweepQueued = false; sweep(); });
}
function sweep() {
  document.querySelectorAll(
    "ytd-rich-item-renderer, ytd-video-renderer, ytd-grid-video-renderer, ytd-compact-video-renderer"
  ).forEach((el) => {
    const t = el.querySelector(".badge-shape-wiz__text, .badge-shape__text")
      ?.textContent.trim().toLowerCase();
    if (t === "sponsored" || t === "promoted") el.style.display = "none";
  });
}
new MutationObserver(queueSweep).observe(document.documentElement, { childList: true, subtree: true });
sweep();

// ── in-video ads ──
// net.js removes the ad schedule from the data, so an ad reaching the
// player here means youtube found another path. handle it fast:
// react to the player's class flips via MutationObserver (skip buttons
// only exist for a moment) with a short interval as backstop.

const SKIP = [
  ".ytp-ad-skip-button",
  ".ytp-ad-skip-button-modern",
  ".ytp-skip-ad-button",                       // current (2024+) skip button
  ".ytp-ad-skip-button-slot button",
  ".ytp-ad-skip-button-container button",
].join(",");

// youtube's "ad blockers violate youtube's tos" wall: it pauses the video
// behind an enforcement dialog. drop the dialog + scrim and unpause.
const WALL = [
  "ytd-popup-container tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)",
  "ytd-popup-container tp-yt-paper-dialog:has(yt-playability-error-supported-renderers)",
].join(",");

function tick() {
  const player = document.getElementById("movie_player");
  const ad = player && (
    player.classList.contains("ad-showing") ||
    player.classList.contains("ad-interrupting")
  );
  if (ad) {
    // 1. click skip the instant it renders
    const skip = player.querySelector(SKIP);
    if (skip) skip.click();
    // 2. no skip button (bumper / unskippable): drag the ad stream to its
    //    end. youtube sometimes restores the position, so keep re-seeking
    //    while the ad is on screen instead of firing once.
    const v = player.querySelector("video.html5-main-video");
    if (v && v.duration && isFinite(v.duration) &&
        v.currentTime < v.duration - 0.5) {
      try { v.currentTime = v.duration - 0.1; } catch {}
    }
  }
  // 3. overlay/display ads on top of the video — css hides the containers;
  //    close clicks are the backstop for variants css doesn't cover
  document.querySelectorAll(
    ".ytp-ad-overlay-close-button, .ytp-ad-overlay-close-container"
  ).forEach((b) => b.click());
  // 4. adblock wall backstop
  const wall = document.querySelector(WALL);
  if (wall) {
    wall.remove();
    document
      .querySelectorAll("tp-yt-iron-overlay-backdrop")
      .forEach((b) => b.remove());
    document.querySelectorAll("video").forEach((v) => {
      if (v.paused) v.play().catch(() => {});
    });
    player?.playVideo?.();
  }
}

// observer on the player element fires within the same frame the
// ad-showing class lands; the element gets replaced on some navigations,
// so re-attach if it ever goes stale.
const po = new MutationObserver(tick);
let observed = null;
function watch() {
  const p = document.getElementById("movie_player");
  if (p && p !== observed) {
    observed = p;
    po.observe(p, { attributes: true, attributeFilter: ["class"], childList: true, subtree: true });
    tick();
  }
}
watch();
setInterval(watch, 5000);
setInterval(tick, 250);
