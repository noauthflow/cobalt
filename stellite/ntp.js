'use strict';

const DEFAULT_ICON = '#C7B8E8';
const STAR_PATH = 'M152.62 237.85L128 256L103.38 237.85L114.568 151.248L45.05 204.22L17 192L20.425 161.635L101.128 128L20.425 94.365L17 64L45.05 51.78L114.568 104.752L103.38 18.15L128 0L152.62 18.15L141.432 104.752L210.95 51.78L239 64L235.575 94.365L154.872 128L235.575 161.635L239 192L210.95 204.22L141.432 151.248L152.62 237.85Z';

const $ = (id) => document.getElementById(id);
const bg = $('bg'), cfg = $('cfg');
const store = chrome.storage.local;

// live settings snapshot; every value mirrors chrome.storage
const S = { iconColor: DEFAULT_ICON, photos: [], ascii: false, intro: true, interactive: true, brightness: 100, menu: true };
let stopAscii = null;

const favicon = (color) =>
  'data:image/svg+xml,' +
  encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><path fill="${color}" d="${STAR_PATH}"/></svg>`);

const setFavicon = (color) => {
  document.querySelector('link[rel="icon"]').href = favicon(color);
};

const persist = (patch) => store.set(patch);

// ---- panel (ctrl+c / fab / esc / backdrop) ----
const openPanel = (open) => cfg.classList.toggle('open', open);
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') return openPanel(false);
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || '');
  const copyHazard = (e.ctrlKey || e.metaKey) && window.getSelection()?.toString();
  if ((e.key === 'c' || e.key === 'C') && (e.ctrlKey || e.metaKey) && !typing && !copyHazard) openPanel(!cfg.classList.contains('open'));
});
cfg.addEventListener('click', (e) => { if (e.target === cfg) openPanel(false); });
$('menubtn').addEventListener('click', () => openPanel(true));

// ---- icon color ----
// every new tab warms the favicon up from white to the saved colour (see warmUp)

// no cache yet (first run / colour just changed): warm the favicon up
// from white to the saved colour instead of popping in.
const warmUp = (to) => {
  const end = [1, 3, 5].map((i) => parseInt(to.slice(i, i + 2), 16));
  const steps = 20; // 20 × 100ms ≈ 2s white → colour fade
  let i = 0;
  setFavicon('#ffffff');
  const t = setInterval(() => {
    i++;
    const mix = (v) => Math.round(255 + (v - 255) * (i / steps));
    setFavicon('#' + end.map((v) => mix(v).toString(16).padStart(2, '0')).join(''));
    if (i >= steps) clearInterval(t);
  }, 100);
};

const applyIcon = (color) => {
  S.iconColor = color;
  setFavicon(color);
  $('iconpick').value = color;
  $('iconhex').value = color;
  persist({ iconColor: color });
};
$('iconpick').addEventListener('input', (e) => applyIcon(e.target.value));
$('iconhex').addEventListener('change', (e) => {
  const v = e.target.value.trim();
  if (/^#[0-9a-f]{6}$/i.test(v)) applyIcon(v.toLowerCase());
  else e.target.value = S.iconColor;
});
$('iconreset').addEventListener('click', () => applyIcon(DEFAULT_ICON));

// ---- photo mode ----
let currentBg = null; // src currently shown on #bg (folder scans check it's still valid)
const showPhoto = () => {
  if (!S.photos.length) return;
  const src = S.photos[Math.floor(Math.random() * S.photos.length)];
  currentBg = src;
  const img = new Image();
  img.onload = () => {
    bg.style.backgroundImage = `url("${src}")`;
    bg.style.filter = `brightness(${S.brightness}%)`;
    requestAnimationFrame(() => bg.classList.add('on'));
  };
  img.src = src;
};

// ---- ascii mode (adjustments are applied at sample time) ----
const startAscii = () => {
  stopAscii?.();
  bg.classList.remove('on');
  bg.style.backgroundImage = '';
  const wrap = $('artwrap');
  wrap.classList.remove('on');
  stopAscii = startAsciiArt($('art'), wrap, S.photos, '#353535', S);
  requestAnimationFrame(() => requestAnimationFrame(() => wrap.classList.add('on')));
};

const showMode = () => {
  if (!S.photos.length) {
    stopAscii?.();
    stopAscii = null;
    $('artwrap').classList.remove('on');
    return;
  }
  if (S.ascii) startAscii();
  else {
    stopAscii?.();
    stopAscii = null;
    $('artwrap').classList.remove('on');
    showPhoto();
  }
};

// ---- photos: a local folder, read live ----
// one folder picked once (File System Access API, opens on the Desktop); the
// handle lives in IndexedDB so it survives browser restarts. a poller rescans
// the folder every 2s, so images added/removed on disk show up without a reload.
const IMG_RE = /\.(png|jpe?g|gif|webp|avif|bmp|svg)$/i;
let dirHandle = null;     // persisted FileSystemDirectoryHandle
let pollTimer = null;
let lastSig = null;       // "name:mtime|..." signature of the last scan
let blobUrls = new Map(); // name -> { url, lastModified } — reused across scans

const idb = {
  db: null,
  open: () => idb.db ? Promise.resolve(idb.db) : new Promise((res, rej) => {
    const r = indexedDB.open('stellite', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('kv');
    r.onsuccess = () => { idb.db = r.result; res(idb.db); };
    r.onerror = () => rej(r.error);
  }),
  get: async (k) => {
    const db = await idb.open();
    return new Promise((res, rej) => {
      const rq = db.transaction('kv').objectStore('kv').get(k);
      rq.onsuccess = () => res(rq.result);
      rq.onerror = () => rej(rq.error);
    });
  },
  set: async (k, v) => {
    const db = await idb.open();
    return new Promise((res, rej) => {
      const tx = db.transaction('kv', 'readwrite');
      if (v === undefined) tx.objectStore('kv').delete(k);
      else tx.objectStore('kv').put(v, k);
      tx.oncomplete = () => res();
      tx.onerror = () => rej(tx.error);
    });
  },
};

const setFolderState = (state) => {
  const card = $('foldercard');
  card.classList.toggle('empty', state === 'empty');
  card.classList.toggle('needs-perm', state === 'needs-perm');
  card.classList.toggle('connected', state === 'connected');
  card.classList.toggle('unsupported', state === 'unsupported');
  $('folderdisconnect').hidden = state !== 'connected';
  $('folderbtn').hidden = state === 'unsupported';
  const labels = { empty: 'Choose folder', 'needs-perm': 'Reconnect', connected: 'Change', unsupported: '' };
  $('folderbtn').textContent = labels[state] ?? '';
};

const setFolderHead = (name, sub) => {
  $('foldername').textContent = name;
  $('foldersub').textContent = sub;
};

const renderPreview = () => {
  const strip = $('strip');
  strip.innerHTML = '';
  strip.hidden = !S.photos.length;
  const max = 10;
  S.photos.slice(0, max).forEach((src) => {
    const t = document.createElement('div');
    t.className = 'th';
    const img = document.createElement('img');
    img.src = src;
    img.alt = '';
    t.append(img);
    strip.append(t);
  });
  const rest = S.photos.length - max;
  if (rest > 0) {
    const m = document.createElement('div');
    m.className = 'th more';
    m.textContent = '+' + rest;
    strip.append(m);
  }
};

const stopPolling = () => { clearInterval(pollTimer); pollTimer = null; };

const setFolderBadge = (n) => {
  const b = $('folderbadge');
  b.textContent = n;
  b.hidden = n == null;
};

const scanFolder = async (dir) => {
  if (!dir) return;
  const files = [];
  try {
    for await (const entry of dir.values()) {
      if (entry.kind !== 'file' || !IMG_RE.test(entry.name)) continue;
      let f;
      try { f = await entry.getFile(); } catch { continue; }
      if (f.size > 0) files.push(f);
    }
  } catch {
    // reads started failing — the permission was probably revoked
    const p = await dir.queryPermission({ mode: 'read' }).catch(() => 'denied');
    if (p !== 'granted') {
      stopPolling();
      setFolderState('needs-perm');
      setFolderHead(dir.name, 'Permission needed to read this folder');
      document.addEventListener('pointerdown', askPerm, true);
      document.addEventListener('keydown', askPerm, true);
    }
    return;
  }
  files.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
  const sig = files.map((f) => f.name + ':' + f.lastModified).join('|');
  if (sig === lastSig) return; // nothing changed on disk
  const hadPhotos = S.photos.length;
  lastSig = sig;

  // rebuild the url list, reusing object urls for files that didn't change
  const next = new Map();
  const urls = [];
  for (const f of files) {
    const prev = blobUrls.get(f.name);
    if (prev && prev.lastModified === f.lastModified) {
      next.set(f.name, prev);
      urls.push(prev.url);
    } else {
      const url = URL.createObjectURL(f);
      next.set(f.name, { url, lastModified: f.lastModified });
      urls.push(url);
    }
  }
  for (const [name, v] of blobUrls) if (!next.has(name)) URL.revokeObjectURL(v.url);
  blobUrls = next;
  S.photos = urls;

  renderPreview();
  const n = urls.length;
  if (n === 0) {
    setFolderBadge(null);
    setFolderHead(dir.name, 'Folder is empty');
  } else {
    setFolderBadge(n);
    setFolderHead(dir.name, '');
  }
  // only (re)pick a background when photos just appeared or the current one vanished
  const vanished = currentBg && !urls.includes(currentBg);
  if ((hadPhotos === 0 && n > 0) || vanished) showMode();
};

const connectFolder = async (dir) => {
  dirHandle = dir;
  lastSig = null;
  await idb.set('dirHandle', dir);
  setFolderState('connected');
  setFolderHead(dir.name, 'Reading folder…');
  await scanFolder(dir);
  stopPolling();
  pollTimer = setInterval(() => { if (!document.hidden) scanFolder(dirHandle); }, 2000);
};
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && dirHandle) scanFolder(dirHandle); // instant catch-up on tab focus
});

const pickFolder = async () => {
  let dir;
  try {
    dir = await window.showDirectoryPicker({ mode: 'read', startIn: 'desktop' });
  } catch { return; } // user cancelled
  await connectFolder(dir);
};

// permission expired (every browser relaunch resets it): Chrome's prompt only
// needs a user gesture, so ask on the first click/keypress on the new tab
// instead of making the user find the Reconnect button in the panel.
let permAsked = false;
const askPerm = async () => {
  if (permAsked || !dirHandle) return;
  permAsked = true;
  document.removeEventListener('pointerdown', askPerm, true);
  document.removeEventListener('keydown', askPerm, true);
  const p = await dirHandle.requestPermission({ mode: 'read' }).catch(() => 'denied');
  if (p === 'granted') return connectFolder(dirHandle);
  permAsked = false; // denied — let the next gesture / button try again
};

$('folderbtn').addEventListener('click', () => {
  // saved folder the browser no longer trusts: ask, don't re-pick
  if (dirHandle && $('foldercard').classList.contains('needs-perm')) {
    askPerm();
    return;
  }
  pickFolder();
});

// ---- adjustments (brightness) ----

const paintSlider = (el) => {
  const pct = ((el.value - el.min) / (el.max - el.min)) * 100;
  el.style.setProperty('--p', pct + '%');
};

$('brightness').addEventListener('input', (e) => {
  S.brightness = +e.target.value;
  $('brightval').textContent = S.brightness + '%';
  paintSlider(e.target);
  // photo mode can adjust live; ascii re-samples on release (below)
  if (!S.ascii && bg.classList.contains('on')) {
    bg.style.filter = `brightness(${S.brightness}%)`;
  }
});
$('brightness').addEventListener('change', (e) => {
  persist({ brightness: S.brightness });
  if (S.ascii) showMode(); // ascii re-samples with new brightness
});

// ---- ascii switch ----
$('folderdisconnect').addEventListener('click', async () => {
  dirHandle = null;
  stopPolling();
  await idb.set('dirHandle', undefined);
  for (const [, v] of blobUrls) URL.revokeObjectURL(v.url);
  blobUrls = new Map();
  lastSig = null;
  S.photos = [];
  currentBg = null;
  renderPreview();
  setFolderBadge(null);
  setFolderState('empty');
  setFolderHead('No folder selected', 'Photos are read live from a local folder');
  stopAscii?.();
  stopAscii = null;
  $('artwrap').classList.remove('on');
  bg.classList.remove('on');
  bg.style.backgroundImage = '';
});

$('asciitoggle').addEventListener('change', (e) => {
  S.ascii = e.target.checked;
  persist({ ascii: S.ascii });
  if (!S.ascii) $('artwrap').classList.remove('on');
  showMode();
});

// intro switch (decode vs fade-in; only affects ascii mode)
$('introtoggle').addEventListener('change', (e) => {
  S.intro = e.target.checked;
  persist({ intro: S.intro });
  if (S.ascii) showMode(); // restart ascii with the new load animation
});

// interactive switch (ascii hover-scramble on/off; live — S is the adj object
// ascii.js reads, so no restart: scrambled cells just heal, no new scrambles)
$('interactivetoggle').addEventListener('change', (e) => {
  S.interactive = e.target.checked;
  persist({ interactive: S.interactive });
});

$('menutoggle').addEventListener('change', (e) => {
  S.menu = e.target.checked;
  persist({ menu: S.menu });
  const btn = $('menubtn');
  if (!S.menu) {
    btn.classList.remove('on');
    btn.style.display = 'none';
  } else {
    btn.style.display = '';
    requestAnimationFrame(() => requestAnimationFrame(() => btn.classList.add('on')));
  }
});

// ---- folder init (after settings load) ----
// restore the saved handle; with Chrome's persistent permissions it usually
// reconnects silently, otherwise any click/keypress on the new tab re-grants
// the read permission (the panel button does the same).
const initFolder = async () => {
  if (!window.showDirectoryPicker) {
    setFolderState('unsupported');
    setFolderHead('Not available', 'Needs a Chromium browser with the File System Access API');
    return;
  }
  const dir = await idb.get('dirHandle').catch(() => null);
  if (!dir) return;
  dirHandle = dir;
  const p = await dir.queryPermission({ mode: 'read' }).catch(() => 'denied');
  if (p === 'granted') connectFolder(dir);
  else {
    setFolderState('needs-perm');
    setFolderHead(dir.name, 'Reconnect to keep using this folder');
    document.addEventListener('pointerdown', askPerm, true);
    document.addEventListener('keydown', askPerm, true);
  }
};

// ---- init ----
store.get(S, (vals) => {
  Object.assign(S, vals);
  S.photos = []; // old stored data urls are obsolete — folder mode owns this now
  store.remove('photos');
  warmUp(S.iconColor); // every new tab: 2s white -> colour fade
  $('iconpick').value = S.iconColor;
  $('iconhex').value = S.iconColor;
  $('asciitoggle').checked = S.ascii;
  $('introtoggle').checked = S.intro;
  $('interactivetoggle').checked = S.interactive;
  $('menutoggle').checked = S.menu;
  $('brightness').value = S.brightness;
  paintSlider($('brightness'));
  $('brightval').textContent = S.brightness + '%';
  setFolderState('empty'); // until a saved folder proves otherwise
  initFolder();
  if (S.menu) {
    // fade the fab in with the bg layers (animation carries the 200ms delay)
    requestAnimationFrame(() => requestAnimationFrame(() => $('menubtn').classList.add('on')));
  } else {
    $('menubtn').style.display = 'none';
  }
  showMode();
});
