// talonite color picker — pick any pixel on screen, copy its color.
//
// oracle: raycast color-picker's "pick-color" command — same flow:
// close main window, system magnifier loupe (NSColorSampler), sRGB out,
// copy + HUD. dropped from the oracle: history, favorites, cross-extension
// callbacks, colorjs.io — one format preference is the whole config surface.

import {
  Clipboard,
  closeMainWindow,
  getPreferenceValues,
  showHUD,
} from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
import { pickColor, PickedColor } from "./native";

type ColorFormat = "hex" | "rgb" | "hsl";

interface Preferences {
  format: ColorFormat;
}

function toHex(c: PickedColor): string {
  const byte = (x: number) =>
    Math.round(Math.min(Math.max(x, 0), 1) * 255)
      .toString(16)
      .padStart(2, "0");
  let hex = `#${byte(c.red)}${byte(c.green)}${byte(c.blue)}`;
  if (c.alpha < 1) hex += byte(c.alpha);
  return hex.toUpperCase();
}

function toRgb(c: PickedColor): string {
  const ch = (x: number) => Math.round(Math.min(Math.max(x, 0), 1) * 255);
  const rgb = `${ch(c.red)}, ${ch(c.green)}, ${ch(c.blue)}`;
  return c.alpha < 1 ? `rgba(${rgb}, ${c.alpha.toFixed(2)})` : `rgb(${rgb})`;
}

function toHsl(c: PickedColor): string {
  const [r, g, b] = [c.red, c.green, c.blue];
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  let h = 0;
  let s = 0;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
  }
  const hsl = `${Math.round(h)}, ${Math.round(s * 100)}%, ${Math.round(l * 100)}%`;
  return c.alpha < 1 ? `hsla(${hsl}, ${c.alpha.toFixed(2)})` : `hsl(${hsl})`;
}

function formatColor(c: PickedColor, format: ColorFormat): string {
  switch (format) {
    case "rgb":
      return toRgb(c);
    case "hsl":
      return toHsl(c);
    default:
      return toHex(c);
  }
}

export default async function Command() {
  const { format } = getPreferenceValues<Preferences>();
  await closeMainWindow();

  try {
    const picked = await pickColor();
    if (!picked) return; // cancelled

    const color = formatColor(picked, format);
    await Clipboard.copy(color);
    await showHUD(`Copied ${color}`);
  } catch (e) {
    await showFailureToast(e, { title: "Failed to pick color" });
  }
}
