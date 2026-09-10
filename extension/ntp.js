'use strict';

const DEFAULT_ICON = '#C7B8E8';
const STAR_PATH = 'M152.62 237.85L128 256L103.38 237.85L114.568 151.248L45.05 204.22L17 192L20.425 161.635L101.128 128L20.425 94.365L17 64L45.05 51.78L114.568 104.752L103.38 18.15L128 0L152.62 18.15L141.432 104.752L210.95 51.78L239 64L235.575 94.365L154.872 128L235.575 161.635L239 192L210.95 204.22L141.432 151.248L152.62 237.85Z';

const $ = (id) => document.getElementById(id);
const bg = $('bg'), cfg = $('cfg'), dropzone = $('dropzone');
const store = chrome.storage.local;

// live settings snapshot; every value mirrors chrome.storage
const S = { iconColor: DEFAULT_ICON, photos: [], ascii: false, intro: true, brightness: 100, blur: 0, menu: true };
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
const showPhoto = () => {
  const src = S.photos[Math.floor(Math.random() * S.photos.length)];
  const img = new Image();
  img.onload = () => {
    bg.style.backgroundImage = `url("${src}")`;
    bg.style.filter = `brightness(${S.brightness}%) blur(${S.blur}px)`;
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

// ---- thumbnails + drag/drop + add tile ----
const setBgInfo = () =>
  $('bginfo').textContent = S.photos.length === 0 ? 'none'
    : S.photos.length === 1 ? '1 photo' : `${S.photos.length} photos`;

const renderThumbs = () => {
  dropzone.querySelectorAll('.ph').forEach((el) => el.remove());
  S.photos.forEach((src, i) => {
    const tile = document.createElement('div');
    tile.className = 'ph';
    const img = document.createElement('img');
    img.src = src;
    img.alt = '';
    const rm = document.createElement('button');
    rm.textContent = '×';
    rm.title = 'Remove';
    rm.addEventListener('click', () => {
      S.photos.splice(i, 1);
      persist({ photos: S.photos });
      renderThumbs();
      setBgInfo();
      showMode();
    });
    tile.append(img, rm);
    dropzone.appendChild(tile);
  });
};

const addFiles = (files) => {
  const imgs = [...files].filter((f) => f.type.startsWith('image/'));
  if (!imgs.length) return;
  Promise.all(imgs.map((f) => new Promise((res) => {
    const r = new FileReader();
    r.onload = () => res(r.result);
    r.readAsDataURL(f);
  }))).then((urls) => {
    S.photos.push(...urls);
    persist({ photos: S.photos });
    renderThumbs();
    setBgInfo();
    showMode();
  });
};

$('addtile').addEventListener('click', () => $('bgfiles').click());
$('bgfiles').addEventListener('change', (e) => {
  addFiles(e.target.files);
  e.target.value = '';
});
;['dragenter', 'dragover'].forEach((ev) =>
  dropzone.addEventListener(ev, (e) => { e.preventDefault(); dropzone.classList.add('dragover'); }));
['dragleave', 'drop'].forEach((ev) =>
  dropzone.addEventListener(ev, (e) => { e.preventDefault(); dropzone.classList.remove('dragover'); }));
dropzone.addEventListener('drop', (e) => addFiles(e.dataTransfer.files));

// ---- adjustments (brightness / blur) ----
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
    bg.style.filter = `brightness(${S.brightness}%) blur(${S.blur}px)`;
  }
});
$('brightness').addEventListener('change', (e) => {
  persist({ brightness: S.brightness });
  if (S.ascii) showMode(); // ascii re-samples with new brightness
});

$('blur').addEventListener('input', (e) => {
  S.blur = +e.target.value;
  $('blurval').textContent = S.blur + 'px';
  paintSlider(e.target);
  if (!S.ascii && bg.classList.contains('on')) {
    bg.style.filter = `brightness(${S.brightness}%) blur(${S.blur}px)`;
  }
});
$('blur').addEventListener('change', (e) => {
  persist({ blur: S.blur });
  if (S.ascii) showMode();
});

// ---- ascii switch ----
$('photoclear').addEventListener('click', () => {
  S.photos = [];
  persist({ photos: S.photos });
  renderThumbs();
  setBgInfo();
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

// ---- init ----
store.get(S, (vals) => {
  Object.assign(S, vals);
  setFavicon(S.iconColor);
  $('iconpick').value = S.iconColor;
  $('iconhex').value = S.iconColor;
  $('asciitoggle').checked = S.ascii;
  $('introtoggle').checked = S.intro;
  $('menutoggle').checked = S.menu;
  $('brightness').value = S.brightness;
  $('blur').value = S.blur;
  paintSlider($('brightness'));
  paintSlider($('blur'));
  $('brightval').textContent = S.brightness + '%';
  $('blurval').textContent = S.blur + 'px';
  setBgInfo();
  renderThumbs();
  if (S.menu) {
    // fade the fab in with the bg layers (animation carries the 200ms delay)
    requestAnimationFrame(() => requestAnimationFrame(() => $('menubtn').classList.add('on')));
  } else {
    $('menubtn').style.display = 'none';
  }
  showMode();
});
