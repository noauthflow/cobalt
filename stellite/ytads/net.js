// ytads/net.js — kill youtube ads at the data layer. runs in the MAIN
// world at document_start, before youtube's own scripts.
//
// in-video ads are scheduled from the player response: youtube hands the
// player a JSON blob containing adPlacements/adSlots describing every ad
// break. strip those keys and the player never learns an ad break exists —
// nothing gets stitched, nothing to skip, zero delay. this covers both the
// response baked into the page html and every /youtubei/v1/player + /next
// response fetched during spa navigation. ads.js is the mop-up for whatever
// still slips through (e.g. server-side stitched ad experiments).
// see ./README.md.

(() => {
  const AD_URL = /\/youtubei\/v1\/(player|next)\b/;
  const AD_KEYS = new Set([
    "adPlacements",
    "adSlots",
    "playerAds",
    "adBreaks",
    "adBreakHeartbeatParams",
  ]);

  // deep-delete every ad-scheduling key in a parsed response
  function scrub(obj) {
    if (Array.isArray(obj)) {
      for (const v of obj) scrub(v);
    } else if (obj && typeof obj === "object") {
      for (const k of Object.keys(obj)) {
        if (AD_KEYS.has(k)) delete obj[k];
        else scrub(obj[k]);
      }
    }
    return obj;
  }

  // ── 1. the first player response ──
  // baked into the page as `var ytInitialPlayerResponse = {...}` (verified:
  // the page source uses var, not window.). a plain property trap works:
  // an existing global binding wins over the var declaration, so the
  // assignment routes through this setter. must run before youtube's
  // inline script — hence document_start.
  let ipr;
  try {
    Object.defineProperty(window, "ytInitialPlayerResponse", {
      get() { return ipr; },
      set(v) { ipr = scrub(v); },
    });
  } catch {}

  // ── 2. every response fetched later ──
  // innertube uses fetch (and falls back to xhr). patch both, scrub the
  // response before the page's json() / .response read sees it.

  // fetch: clone, scrub the clone, hand the page a rebuilt Response with
  // identical status/headers. on any failure, return the pristine
  // original — never break a load over this.
  const of = window.fetch;
  window.fetch = function (input, init) {
    const p = of.apply(this, arguments);
    const url = typeof input === "string" ? input
      : input && typeof input === "object" ? input.url : "";
    if (!AD_URL.test(String(url))) return p;
    return p.then((res) => {
      try {
        return res.clone().json().then((j) => new Response(JSON.stringify(scrub(j)), {
          status: res.status,
          statusText: res.statusText,
          headers: res.headers,
        })).catch(() => res);
      } catch {
        return res;
      }
    });
  };

  // xhr: shadow responseText/response with instance-level getters that
  // scrub on first read. defined at send() time so they're in place
  // before the page's load handler reads the body (listener order puts
  // youtube's handler first, so the getter must already exist by then).
  if (typeof XMLHttpRequest === "undefined") return;
  const oo = XMLHttpRequest.prototype.open;
  const os = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) {
    this.__ytadsUrl = u;
    return oo.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    try {
      if (AD_URL.test(String(this.__ytadsUrl ?? ""))) {
        const t = this.responseType;
        if (t === "json") {
          const native = Object.getOwnPropertyDescriptor(
            XMLHttpRequest.prototype, "response").get;
          Object.defineProperty(this, "response", {
            get() {
              const j = native.call(this);
              if (j && !this.__ytadsDone) { this.__ytadsDone = true; scrub(j); }
              return j;
            },
            configurable: true,
          });
        } else if (t === "" || t === "text") {
          const native = Object.getOwnPropertyDescriptor(
            XMLHttpRequest.prototype, "responseText").get;
          Object.defineProperty(this, "responseText", {
            get() {
              let s = native.call(this);
              if (s && !this.__ytadsDone) {
                this.__ytadsDone = true;
                try { s = JSON.stringify(scrub(JSON.parse(s))); } catch {}
              }
              return s;
            },
            configurable: true,
          });
        }
      }
    } catch {}
    return os.apply(this, arguments);
  };
})();
