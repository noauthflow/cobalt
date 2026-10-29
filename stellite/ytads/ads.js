// ytads — youtube ad blocker, in-video + feed sweep.
// paired with hide.css in this folder. see ./README.md.

// feed items that slip past the css selectors: anything badged
// "Sponsored" / "Promoted" (youtube renames ad renderers often, the
// badge text is the stable signal)
function clean() {
  document.querySelectorAll(
    "ytd-rich-item-renderer, ytd-video-renderer, ytd-grid-video-renderer, ytd-compact-video-renderer"
  ).forEach((el) => {
    const t = el.querySelector(".badge-shape-wiz__text, .badge-shape__text")
      ?.textContent.trim().toLowerCase();
    if (t === "sponsored" || t === "promoted") el.style.display = "none";
  });
}

new MutationObserver(clean).observe(document.documentElement, { childList: true, subtree: true });
clean();

// ── in-video ads ──
// the ad is stitched into the stream, so it can't be blocked at the request
// level by a simple extension. instead: watch the player's ad state, click
// skip when the button exists, and fast-forward the ad stream to its end.
const ffed = new WeakSet(); // ad videos already fast-forwarded

function ads() {
  const player = document.getElementById("movie_player");
  if (player) {
    if (player.classList.contains("ad-showing")) {
      const skip = player.querySelector(
        ".ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-slot button"
      );
      if (skip) skip.click();
      const v = player.querySelector("video");
      if (v && !ffed.has(v) && v.duration && isFinite(v.duration)) {
        ffed.add(v);
        try { v.currentTime = Math.max(0, v.duration - 0.1); } catch {}
      }
    } else {
      player.querySelectorAll("video").forEach((v) => ffed.delete(v));
    }
  }
  // display/overlay ads on top of the video
  document.querySelectorAll(
    ".ytp-ad-overlay-close-button, .ytp-ad-overlay-close-container"
  ).forEach((b) => b.click());
}

setInterval(ads, 500);
