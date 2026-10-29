// popblock — kill popups / popunders on every site.
// hardened against the exo/iclick-style PPU kits that stream sites load
// (anikoto.cz → nekostream.site → llvpn.com/tag.min.js): they open popups
// via window.open, via form.submit() to a named/_blank target, via child
// frames, probe window.open.toString(), and run anti-devtools console
// tricks (spams/clears the console so you can't debug).
//
// layers:
//  0. network — rules.json (declarativeNetRequest) blocks the known popunder
//     kit domains outright; no script load, no popunder, no console games.
//     new annoying site → add its ad domain there.
//  1. sandbox stripping — popunders firing from a sandboxed player iframe
//     ("allow-popups" in its sandbox attr) get the tokens stripped from the
//     top page; chrome injects no content scripts into sandboxed frames.
//  2. opener side — window.open stubbed in every reachable realm (top +
//     same-origin/about:blank child frames), returning a fake window.
//     toString() is spoofed to look native. ctrl/cmd lets one through.
//  3. form side — script-called form.submit()/requestSubmit() to a _blank
//     or no-such-frame named target is dropped (the kit's main bypass), and
//     untrusted submit events on such forms are canceled.
//  4. popup side (uBO Lite prevent-popup trick) — any tab that still
//     spawns closes itself instantly: script may close script-opened tabs,
//     never user-opened ones.
//  5. synthetic anchor clicks — a.target="_blank"; a.click() canceled
//     (untrusted clicks only, real ones pass).
//  6. debugging — console.clear() neutralized, and an on-page badge shows
//     armed/blocked counts visually (pages can't hide that from you), plus
//     a self.__popblock.log buffer. click the badge to dump the log.

const TAG = "[popblock]";
const noop = () => {};

// ── layer 6a: stop the page from wiping the console ──
try { console.clear = noop; } catch {}

// ── layer 6b: log buffer + on-page badge (top frame only) ──
const stats = (self.__popblock = self.__popblock || { blocked: 0, allowed: 0, log: [] });

function log(kind, msg) {
  try {
    if (kind === "blocked") stats.blocked++;
    if (kind === "allowed") stats.allowed++;
    stats.log.push(new Date().toISOString().slice(11, 23) + " " + kind + " " + msg);
    if (stats.log.length > 300) stats.log.shift();
  } catch {}
  console.debug(TAG, kind, msg);
}

let badge, badgeTimer;
function ensureBadge() {
  if (badge && badge.isConnected) return badge;
  badge = document.createElement("div");
  badge.textContent = "popblock";
  Object.assign(badge.style, {
    position: "fixed", right: "10px", bottom: "10px", zIndex: "2147483647",
    padding: "4px 10px", borderRadius: "8px",
    font: "600 11px system-ui, sans-serif", color: "#fff",
    background: "#3d5afe", opacity: "0", transition: "opacity .25s",
    pointerEvents: "auto", boxShadow: "0 1px 4px rgba(0,0,0,.4)",
    userSelect: "none",
  });
  badge.addEventListener("click", () => {
    console.log(TAG, "blocked:", stats.blocked, "allowed:", stats.allowed);
    console.log(stats.log.join("\n"));
  });
  (document.body || document.documentElement).appendChild(badge);
  return badge;
}
function showBadge(text, color, ms) {
  try {
    if (self !== self.top) return;
    const b = ensureBadge();
    b.textContent = text;
    b.style.background = color;
    b.style.opacity = "1";
    clearTimeout(badgeTimer);
    badgeTimer = setTimeout(() => { if (badge) badge.style.opacity = "0"; }, ms || 1500);
  } catch {}
}
function onReady(fn) {
  if (document.readyState !== "loading") fn();
  else document.addEventListener("DOMContentLoaded", fn);
}
onReady(() => showBadge("popblock armed", "#3d5afe", 2500));

// ── layer 1: strip popup tokens from iframe sandboxes ──
// only touches iframes that already HAVE a sandbox attribute; a plain
// iframe is left alone (adding sandbox would break half the web).
const POPUP_TOKEN = /^allow-popups(-to-escape-sandbox)?$/;

function stripSandbox(iframe) {
  const s = iframe.getAttribute("sandbox");
  if (!s) return;
  const kept = s.split(/\s+/).filter((t) => t && !POPUP_TOKEN.test(t)).join(" ");
  if (kept !== s) {
    iframe.setAttribute("sandbox", kept);
    log("stripped", "iframe sandbox: " + s + " -> " + kept);
  }
}
function sweepSandbox(root) {
  if (root.querySelectorAll) root.querySelectorAll("iframe").forEach(stripSandbox);
}
new MutationObserver((muts) => {
  for (const m of muts) {
    if (m.type === "attributes" && m.target.tagName === "IFRAME") stripSandbox(m.target);
    else for (const n of m.addedNodes) {
      if (n.tagName === "IFRAME") stripSandbox(n);
      else if (n.querySelectorAll) sweepSandbox(n);
    }
  }
}).observe(document.documentElement || document, {
  childList: true, subtree: true, attributes: true, attributeFilter: ["sandbox"],
});
sweepSandbox(document);

// ── layer 4 (popup side): close script-spawned tabs instantly ──
if (self === self.top) {
  try {
    if (window.opener && window.opener !== window) {
      log("closed", "script-spawned popup: " + location.href);
      window.close();
    }
  } catch {}
}

// ── layer 2 (opener side): stub window.open in every reachable realm ──
// minimal stand-in window: survives the usual post-open poking
// (w.location.href = ..., w.document.write(...), w.focus(), w.closed checks)
const fakeWin = {
  closed: false,
  opener: null,
  name: "",
  focus: noop, blur: noop, close: noop, print: noop, postMessage: noop,
  moveTo: noop, moveBy: noop, resizeTo: noop, resizeBy: noop,
  scrollTo: noop, scrollBy: noop,
  addEventListener: noop, removeEventListener: noop, dispatchEvent: noop,
  location: {
    href: "about:blank",
    assign: noop, replace: noop, reload: noop,
    toString: () => "about:blank",
  },
  document: {
    write: noop, writeln: noop, open: noop, close: noop,
    body: null, documentElement: null,
  },
  frames: [],
  length: 0,
};

// popunders fire on plain clicks; a held modifier is a reliable "i meant it"
let allowOnce = false;
self.addEventListener("click", (e) => { allowOnce = e.ctrlKey || e.metaKey; }, true);
self.addEventListener("keydown", (e) => {
  if (e.key === "Enter") allowOnce = e.ctrlKey || e.metaKey;
}, true);

const NATIVE_TOSTRING = "function open() { [native code] }";

function makeStub(win) {
  const real = win.open;
  const stub = function open(url, name, features) {
    if (allowOnce) {
      allowOnce = false;
      log("allowed", "ctrl/cmd: " + url);
      showBadge("popblock · allowed 1 (ctrl)", "#00897b", 1200);
      return real.call(win, url, name, features);
    }
    // _self/_top/_parent replace the current window instead of opening a
    // tab; not popups, let them be.
    if (typeof name === "string" && /^(?:_self|_top|_parent)$/.test(name)) {
      return real.call(win, url, name, features);
    }
    log("blocked", "window.open: " + url);
    showBadge("popblock · " + stats.blocked + " blocked", "#d93025", 1800);
    // fresh object per call so one handle's mutations don't leak into
    // another (Object.create keeps the shared methods on the prototype)
    return Object.create(fakeWin);
  };
  // kits probe window.open.toString() for "[native code]"; play along
  Object.defineProperty(stub, "toString", {
    value: () => NATIVE_TOSTRING, writable: true, configurable: true,
  });
  return stub;
}

window.open = makeStub(window);

// the kit can also open through same-origin/about:blank child frames
// (window.open is native again in every new realm). walk what we can reach;
// cross-origin frames throw and are covered by their own content script.
function stubFrames(win, depth) {
  if (!win || depth > 8) return;
  try {
    if (!win.__popblockStubbed) {
      win.__popblockStubbed = true;
      win.open = makeStub(win);
    }
  } catch { return; } // cross-origin: not ours to reach
  try {
    for (let i = 0; i < win.frames.length; i++) stubFrames(win.frames[i], depth + 1);
  } catch {}
}
function sweepFrames() { stubFrames(self, 0); }
sweepFrames();

// ── layer 3 (form side): the kit's main bypass ──
// script-called submit() to _blank, or to a named target with no matching
// frame, would conjure a brand-new real tab. drop those.
function formOpensPopup(form) {
  const t = form.target;
  if (!t || t === "_self" || t === "_top" || t === "_parent") return false;
  if (t === "_blank") return true;
  try {
    if (form.ownerDocument.defaultView.frames[t] != null) return false;
  } catch {}
  return true;
}
const realSubmit = HTMLFormElement.prototype.submit;
const realRequestSubmit = HTMLFormElement.prototype.requestSubmit;
HTMLFormElement.prototype.submit = function () {
  if (formOpensPopup(this)) {
    log("blocked", "script form.submit: " + this.target + " " + this.action);
    showBadge("popblock · " + stats.blocked + " blocked", "#d93025", 1800);
    return;
  }
  return realSubmit.apply(this, arguments);
};
if (realRequestSubmit) {
  HTMLFormElement.prototype.requestSubmit = function (submitter) {
    if (formOpensPopup(this)) {
      log("blocked", "script form.requestSubmit: " + this.target + " " + this.action);
      showBadge("popblock · " + stats.blocked + " blocked", "#d93025", 1800);
      return;
    }
    return realRequestSubmit.call(this, submitter);
  };
}
// fallback for kits that set the target then trigger a synthetic submit event
document.addEventListener("submit", (e) => {
  if (e.isTrusted) return;
  if (e.target instanceof HTMLFormElement && formOpensPopup(e.target)) {
    log("blocked", "synthetic submit: " + e.target.target + " " + e.target.action);
    e.preventDefault();
  }
}, true);

// ── layer 5: synthetic clicks on target="_blank" anchors ──
document.addEventListener("click", (e) => {
  if (e.isTrusted) return;
  const a = e.target && e.target.closest && e.target.closest('a[target="_blank"]');
  if (a) {
    log("blocked", "synthetic click on: " + a.href);
    showBadge("popblock · " + stats.blocked + " blocked", "#d93025", 1800);
    e.preventDefault();
    e.stopPropagation();
  }
}, true);

// upkeep: new frames and iframes appear all the time on stream sites;
// also re-attach the badge if the page removed it
setInterval(() => {
  sweepFrames();
  sweepSandbox(document);
  if (self === self.top && badge && !badge.isConnected && document.body) {
    document.body.appendChild(badge);
  }
}, 1000);

onReady(() => console.info(TAG, "armed on", location.host));
