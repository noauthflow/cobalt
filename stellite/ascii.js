// ASCII art renderer for the new tab page. Port of aeolian's
// components/ui/DotImage.tsx (same constants, same spacing, same algorithm):
// renders one of the stored photos (picked at random per load) as ASCII art
// on a canvas. On load it plays a "decode" intro: the whole panel starts as
// flickering random characters and resolves into the real image top to
// bottom, like a terminal decrypting. The grid is keyed off "whiteness"
// (luminance) so subjects separate from background, tinted from the image's
// own palette. Covers the full page, fills its positioned parent, redraws on
// resize. adj.intro selects the load animation: true = "decode" intro
// (flickering COBALT resolving top to bottom), false = plain fade-in of the
// finished image.
const CELL_W = 7 // px per character column
const CELL_H = 12 // px per character row (also the font size)
const RAMP = " .,:;-~=+i!lI/\\|()1[]{}rcvzxnufjtLCJUYXZ0OQmwqpdbkhao*#MW&8%B@$" // sparse -> dense
const WORD = 'COBALT' // spelled, repeating + scrolling, in the loading/decode state
const DURATION = 1600 // ms for the decode
const HOVER_RADIUS = 72 // px around the cursor that scrambles on hover
const HOVER_JITTER = 22 // px of per-cell radius jitter, so the edge isn't a clean circle
const HOVER_CHARS = '!<>-_/\\[]{}*+=?#%&@$~^cyd' // random symbols shown on hover
const HEAL_MS = 1000 // a scrambled glyph heals back this long after last touched
const SAT = 1.25 // colour push away from grey; aeolian's 1.8 was tuned for white
                 // clouds and turns normal photos neon
const BRIGHTEN = 1.0 // aeolian multiplies 1.12 on top; not needed full-stop

function startAsciiArt(canvas, parent, srcs, background = '#353535', adj = { brightness: 100, blur: 0 }) {
  const ctx = canvas.getContext('2d')
  const src = srcs[Math.floor(Math.random() * srcs.length)]
  const img = new Image()
  img.decoding = 'async'
  let raf = 0
  let hoverRaf = 0
  let played = false
  let cssW = 0
  let cssH = 0
  let cols = 0
  let rows = 0
  let chars = [] // final glyph per cell ('' = blank)
  let colors = [] // final fillStyle per cell
  let loadColors = [] // per-cell colour during decode (random from the palette)
  let revealAt = new Float32Array(0) // 0..1 point in the intro a cell resolves
  // Hover-scramble state.
  let ready = false // intro finished; hover enabled
  let mx = -1
  let my = -1
  let scrambleChar = [] // per-cell scrambled glyph (fixed until healed)
  let scrambleExp = new Float64Array(0) // per-cell time (ms) the scramble heals back
  let noise = new Float32Array(0) // per-cell stable jitter for an irregular edge
  let inside = false // pointer currently over the panel

  const setup = () => {
    if (!img.complete || img.naturalWidth === 0) return false
    cssW = parent.clientWidth
    cssH = parent.clientHeight
    if (cssW === 0 || cssH === 0) return false

    const dpr = Math.min(window.devicePixelRatio || 1, 2)
    canvas.width = Math.round(cssW * dpr)
    canvas.height = Math.round(cssH * dpr)
    canvas.style.width = `${cssW}px`
    canvas.style.height = `${cssH}px`
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    cols = Math.ceil(cssW / CELL_W)
    rows = Math.ceil(cssH / CELL_H)

    const off = document.createElement('canvas')
    off.width = cols
    off.height = rows
    const octx = off.getContext('2d', { willReadFrequently: true })
    if (!octx) return false
    // user adjustments, applied at sample time. the offscreen grid is ~1px per
    // character cell, so the screen-space blur is divided down to match.
    octx.filter = `brightness(${adj.brightness}%) blur(${(adj.blur / CELL_W).toFixed(2)}px)`
    const imgRatio = img.naturalWidth / img.naturalHeight
    const gridRatio = cols / rows
    let sw, sh, sx, sy
    if (imgRatio > gridRatio) {
      sh = img.naturalHeight
      sw = sh * gridRatio
      sx = (img.naturalWidth - sw) / 2
      sy = 0
    } else {
      sw = img.naturalWidth
      sh = sw / gridRatio
      sx = 0
      sy = (img.naturalHeight - sh) / 2
    }
    octx.drawImage(img, sx, sy, sw, sh, 0, 0, cols, rows)
    const data = octx.getImageData(0, 0, cols, rows).data

    const n = cols * rows
    chars = new Array(n)
    colors = new Array(n)
    loadColors = new Array(n)
    revealAt = new Float32Array(n)
    scrambleChar = new Array(n).fill('')
    scrambleExp = new Float64Array(n)
    noise = new Float32Array(n)
    for (let p = 0; p < n; p++) noise[p] = Math.random()

    // Pass 1: luminance per cell + overall min/max, so we can contrast-stretch
    // each image to use the full character range. Transparent cells (blur bleed
    // at the crop edges) are excluded from the stretch and blanked in pass 2.
    const lum = new Float32Array(n)
    const opaque = new Uint8Array(n)
    let lmin = 1
    let lmax = 0
    for (let p = 0; p < n; p++) {
      const i4 = p * 4
      opaque[p] = data[i4 + 3] > 127 ? 1 : 0
      const L = (0.299 * data[i4] + 0.587 * data[i4 + 1] + 0.114 * data[i4 + 2]) / 255
      lum[p] = L
      if (opaque[p]) {
        if (L < lmin) lmin = L
        if (L > lmax) lmax = L
      }
    }
    const range = Math.max(1e-4, lmax - lmin)

    // Pass 2: map each cell to a glyph (brighter -> denser) + a tint.
    const last = RAMP.length - 1
    for (let p = 0; p < n; p++) {
      const v = Math.min(1, Math.max(0, (lum[p] - lmin) / range))
      const ch = RAMP[Math.min(last, Math.floor(v * RAMP.length))]
      if (ch === ' ' || !opaque[p]) {
        chars[p] = ''
      } else {
        chars[p] = ch
        // Push each pixel's colour away from grey (saturation boost) and
        // brighten a touch, so hues read distinctly instead of a flat tint.
        const i4 = p * 4
        const L = 0.299 * data[i4] + 0.587 * data[i4 + 1] + 0.114 * data[i4 + 2]
        const cr = Math.min(255, Math.max(0, (L + (data[i4] - L) * SAT) * BRIGHTEN))
        const cg = Math.min(255, Math.max(0, (L + (data[i4 + 1] - L) * SAT) * BRIGHTEN))
        const cb = Math.min(255, Math.max(0, (L + (data[i4 + 2] - L) * SAT) * BRIGHTEN))
        colors[p] = `rgb(${cr | 0},${cg | 0},${cb | 0})`
      }
      // Resolve top -> bottom with a little per-cell jitter.
      const rowFrac = Math.floor(p / cols) / rows
      revealAt[p] = Math.min(0.999, rowFrac * 0.72 + Math.random() * 0.28)
    }

    // Sample the image's actual palette, then give every cell a RANDOM colour
    // from it for the decode. This way the image isn't recognisable at t=0 —
    // the real hues only fall into place as each row resolves.
    const palette = []
    for (let p = 0; p < n; p++) if (chars[p]) palette.push(colors[p])
    const pl = palette.length
    for (let p = 0; p < n; p++) {
      loadColors[p] = pl ? palette[(Math.random() * pl) | 0] : colors[p]
    }
    return true
  }

  // Draw the grid at intro progress t (1 = fully decoded). Resolved cells show
  // their final glyph; unresolved cells flicker a random glyph.
  const drawFrame = (t, step = 0) => {
    ctx.globalAlpha = 1
    ctx.fillStyle = background
    ctx.fillRect(0, 0, cssW, cssH)
    ctx.font = `${CELL_H}px ui-monospace, SFMono-Regular, Menlo, monospace`
    ctx.textBaseline = 'top'
    ctx.textAlign = 'left'
    const wl = WORD.length
    for (let j = 0; j < rows; j++) {
      const y = j * CELL_H
      const rowBase = j * cols
      for (let i = 0; i < cols; i++) {
        const p = rowBase + i
        const finalCh = chars[p]
        if (!finalCh) continue // keep whitespace blank the whole time
        if (t >= revealAt[p]) {
          ctx.fillStyle = colors[p]
          ctx.fillText(finalCh, i * CELL_W, y)
        } else {
          // Loading state: spell COBALT across each row (scrolling by `step`),
          // each cell a random palette colour so the image stays hidden.
          ctx.fillStyle = loadColors[p]
          ctx.fillText(WORD[(i + step) % wl], i * CELL_W, y)
        }
      }
    }
  }

  // Hover trail: cursor movement scrambles nearby glyphs to a random symbol
  // ONCE (fixed, not flickering); each scrambled cell heals back to the image
  // HEAL_MS after it was last touched. A light loop runs only while cells are
  // still scrambled, then stops.
  const MAX_R = HOVER_RADIUS + HOVER_JITTER
  // Scramble (once) and keep-alive the heal timer for cells within a jittered
  // radius of the current cursor. Called on move AND every loop frame while the
  // pointer is inside, so a cell under a stationary cursor never heals.
  const scrambleAround = (now) => {
    const hl = HOVER_CHARS.length
    const iMin = Math.max(0, Math.floor((mx - MAX_R) / CELL_W))
    const iMax = Math.min(cols - 1, Math.ceil((mx + MAX_R) / CELL_W))
    const jMin = Math.max(0, Math.floor((my - MAX_R) / CELL_H))
    const jMax = Math.min(rows - 1, Math.ceil((my + MAX_R) / CELL_H))
    for (let j = jMin; j <= jMax; j++) {
      const cy = j * CELL_H + CELL_H / 2
      for (let i = iMin; i <= iMax; i++) {
        const p = j * cols + i
        if (!chars[p]) continue
        const dx = i * CELL_W + CELL_W / 2 - mx
        const dy = cy - my
        // Per-cell jittered radius so the boundary is irregular, not a circle.
        const r = HOVER_RADIUS + (noise[p] * 2 - 1) * HOVER_JITTER
        if (dx * dx + dy * dy < r * r) {
          if (scrambleExp[p] <= now) scrambleChar[p] = HOVER_CHARS[(Math.random() * hl) | 0]
          scrambleExp[p] = now + HEAL_MS
        }
      }
    }
  }
  const drawScrambleFrame = (now) => {
    ctx.globalAlpha = 1
    ctx.fillStyle = background
    ctx.fillRect(0, 0, cssW, cssH)
    ctx.font = `${CELL_H}px ui-monospace, SFMono-Regular, Menlo, monospace`
    ctx.textBaseline = 'top'
    ctx.textAlign = 'left'
    let active = false
    for (let j = 0; j < rows; j++) {
      const y = j * CELL_H
      const rowBase = j * cols
      for (let i = 0; i < cols; i++) {
        const p = rowBase + i
        const ch = chars[p]
        if (!ch) continue
        ctx.fillStyle = colors[p]
        if (scrambleExp[p] > now) {
          active = true
          ctx.fillText(scrambleChar[p], i * CELL_W, y)
        } else {
          ctx.fillText(ch, i * CELL_W, y)
        }
      }
    }
    return active
  }
  const loop = () => {
    const now = performance.now()
    if (inside) scrambleAround(now) // hold cells under a stationary cursor
    if (drawScrambleFrame(now)) {
      hoverRaf = requestAnimationFrame(loop)
    } else {
      hoverRaf = 0
      drawFrame(1) // fully healed: clean static image
    }
  }
  const onMove = (e) => {
    // ready alone isn't enough: the ResizeObserver's initial callback can draw
    // the final image and set ready before the intro ever plays (fast data-URL
    // decode). raf non-zero means the intro is still mid-flight — no hover.
    if (!ready || raf) return
    const rect = canvas.getBoundingClientRect()
    mx = e.clientX - rect.left
    my = e.clientY - rect.top
    // Tracking is document-level (the pane is pointer-events:none so the
    // photo-bg layer and page stay interactive), so ignore the cursor when
    // it's outside the pane.
    if (mx < 0 || my < 0 || mx > cssW || my > cssH) {
      inside = false
      return
    }
    inside = true
    scrambleAround(performance.now())
    if (!hoverRaf) hoverRaf = requestAnimationFrame(loop)
  }
  const onLeave = () => {
    // Stop holding cells; they heal HEAL_MS after the pointer left them.
    inside = false
  }
  document.addEventListener('mousemove', onMove)
  document.addEventListener('mouseleave', onLeave)

  const runIntro = () => {
    let startT = null
    const frame = (now) => {
      if (startT === null) startT = now
      const elapsed = now - startT
      const t = Math.min(1, elapsed / DURATION)
      // Scroll the COBALT text forward one cell every ~90ms.
      drawFrame(t, Math.floor(elapsed / 90))
      if (t < 1) {
        raf = requestAnimationFrame(frame)
      } else {
        raf = 0
        drawFrame(1)
        ready = true
      }
    }
    raf = requestAnimationFrame(frame)
  }

  const start = () => {
    if (!setup()) return
    // Fade mode (adj.intro false): skip the decode entirely — draw the final
    // grid and let #artwrap's css opacity transition do the fade-in.
    if (adj.intro === false) {
      drawFrame(1)
      ready = true
      return
    }
    // ready may already be true here: the ResizeObserver's initial callback
    // can draw the final image before onload. in that case skip the intro —
    // replaying it would interleave decode flicker with live hover frames.
    if (!played && !ready) {
      played = true
      runIntro()
    } else {
      drawFrame(1)
      ready = true
    }
  }

  img.onload = start
  img.src = src
  if (img.complete) start()

  const ro = new ResizeObserver(() => {
    if (parent.clientWidth === cssW && parent.clientHeight === cssH) return
    cancelAnimationFrame(raf)
    cancelAnimationFrame(hoverRaf)
    hoverRaf = 0
    if (setup()) {
      drawFrame(1)
      ready = true
    }
  })
  ro.observe(parent)

  return () => {
    ro.disconnect()
    cancelAnimationFrame(raf)
    cancelAnimationFrame(hoverRaf)
    document.removeEventListener('mousemove', onMove)
    document.removeEventListener('mouseleave', onLeave)
  }
}
