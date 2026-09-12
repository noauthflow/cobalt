// hides Shorts everywhere element names can't do it alone:
// sidebar/mini-guide entries (matched by title text) and individual
// grid/search items that link to /shorts/.
function clean() {
  document.querySelectorAll(
    "ytd-guide-entry-renderer, ytd-mini-guide-entry-renderer, ytd-guide-collapsible-entry-renderer"
  ).forEach((el) => {
    const t = el.querySelector(".title");
    if (t && t.textContent.trim().toLowerCase() === "shorts") el.style.display = "none";
  });

  document.querySelectorAll(
    "ytd-video-renderer, ytd-grid-video-renderer, ytd-rich-item-renderer"
  ).forEach((el) => {
    if (el.closest("ytd-rich-shelf-renderer")) return; // shelf hidden by css
    if (el.querySelector('a[href*="/shorts/"]')) el.style.display = "none";
  });
}

new MutationObserver(clean).observe(document.documentElement, { childList: true, subtree: true });
clean();

// opening a /shorts/ url sends you to the normal watch page instead
if (location.pathname.startsWith("/shorts/")) {
  const id = location.pathname.split("/")[2];
  if (id) location.replace("https://www.youtube.com/watch?v=" + id);
}
