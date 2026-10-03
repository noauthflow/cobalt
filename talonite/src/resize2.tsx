// talonite resize (slot 2) — thin wrapper; logic lives in resize-core.ts.
// size & position are configured in Raycast's settings for this command.

import { getPreferenceValues } from "@raycast/api";
import { runResize } from "./resize-core";

interface Preferences {
  size: string;
  pos: string;
}

export default async function Command() {
  await runResize(getPreferenceValues<Preferences>());
}
