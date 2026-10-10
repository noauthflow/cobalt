// talonite cleanshot — opens CleanShot X's capture history via its URL scheme.

import { open } from "@raycast/api";

export default async function Command() {
  await open("cleanshot://open-history");
}
