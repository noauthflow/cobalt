// shared resize logic — used by the resize, resize2, and resize3 commands.
// each command has its own size/pos preferences in Raycast settings.

import { WindowManagement, showHUD } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";

// ── fallbacks, used when a preference is blank ────────────────────────
const DEFAULT_SIZE = "50%x100%"; // "1280x800", "50%", "50%x100%"
const DEFAULT_POS = "center";    // center | left | right | top | bottom |
                                 // corners | "X,Y" pixels
// ────────────────────────────────────────────────────────────────────────

interface Preferences {
  size: string;
  pos: string;
}

interface Spec {
  w: number | { pct: number };
  h: number | { pct: number };
  pos?: { x?: number; y?: number };
}

function parse(spec: { size: string; pos: string }): Spec {
  const [size, pos = ""] = [spec.size, spec.pos];

  const parseDim = (s: string): number | { pct: number } =>
    s.endsWith("%") ? { pct: parseFloat(s.slice(0, -1)) } : parseFloat(s);

  let w: number | { pct: number };
  let h: number | { pct: number };
  if (size.includes("x")) {
    const [ws, hs] = size.split("x");
    w = parseDim(ws);
    h = parseDim(hs);
  } else {
    w = parseDim(size);
    h = parseDim(size);
  }

  let position: { x?: number; y?: number } | undefined;
  if (pos.includes(",")) {
    const [xs, ys] = pos.split(",");
    position = { x: parseFloat(xs), y: parseFloat(ys) };
  }

  return { w, h, pos: position };
}

export async function runResize(prefs: Preferences) {
  try {
    const size = (prefs.size || DEFAULT_SIZE).trim().toLowerCase();
    const pos = (prefs.pos || DEFAULT_POS).trim().toLowerCase();

    const win = await WindowManagement.getActiveWindow();

    if (typeof win.bounds === "string") {
      await showHUD("Window is fullscreen — exit fullscreen first");
      return;
    }
    if (!win.resizable) {
      await showHUD("Window is not resizable");
      return;
    }

    const desktops = await WindowManagement.getDesktops();
    const desktop = desktops.find((d) => d.id === win.desktopId);
    if (!desktop) {
      await showHUD("Couldn't find the active desktop");
      return;
    }
    const sw = desktop.size.width;
    const sh = desktop.size.height;

    const { w: wSpec, h: hSpec, pos: posSpec } = parse({ size, pos });

    const tw = Math.min(typeof wSpec === "number" ? wSpec : Math.round((sw * wSpec.pct) / 100), sw);
    const th = Math.min(typeof hSpec === "number" ? hSpec : Math.round((sh * hSpec.pct) / 100), sh);

    let x: number;
    let y: number;
    if (posSpec) {
      x = posSpec.x ?? Math.round((sw - tw) / 2);
      y = posSpec.y ?? Math.round((sh - th) / 2);
    } else if (pos === "left") {
      x = 0;
      y = 0;
    } else if (pos === "right") {
      x = sw - tw;
      y = 0;
    } else if (pos === "top") {
      x = Math.round((sw - tw) / 2);
      y = 0;
    } else if (pos === "bottom") {
      x = Math.round((sw - tw) / 2);
      y = sh - th;
    } else if (pos === "top-left") {
      x = 0;
      y = 0;
    } else if (pos === "top-right") {
      x = sw - tw;
      y = 0;
    } else if (pos === "bottom-left") {
      x = 0;
      y = sh - th;
    } else if (pos === "bottom-right") {
      x = sw - tw;
      y = sh - th;
    } else {
      x = Math.round((sw - tw) / 2);
      y = Math.round((sh - th) / 2);
    }

    await WindowManagement.setWindowBounds({
      id: win.id,
      bounds: { position: { x, y }, size: { width: tw, height: th } },
    });
  } catch (e) {
    await showFailureToast(e, { title: "Failed to resize window" });
  }
}
