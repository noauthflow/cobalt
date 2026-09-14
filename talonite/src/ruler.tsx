// talonite ruler — distance between two points on screen, in pixels.
//
// oracle: raycast "ruler" — same flow: close main window, crosshair overlay
// (click point A and point B, or drag A to B in drag mode), distance string
// back, copy to clipboard. dropped from the oracle: the copy-to-clipboard
// preference — that's the whole point here, it always copies.

import {
  Clipboard,
  closeMainWindow,
  getPreferenceValues,
  showHUD,
} from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
import { measureDistance } from "./native";

interface Preferences {
  dragMode: boolean;
}

export default async function Command() {
  const { dragMode } = getPreferenceValues<Preferences>();
  await closeMainWindow();

  try {
    const distance = await measureDistance(dragMode);
    if (!distance) return; // cancelled

    await Clipboard.copy(distance);
    await showHUD(`Copied ${distance} px`);
  } catch (e) {
    await showFailureToast(e, { title: "Failed to measure distance" });
  }
}
