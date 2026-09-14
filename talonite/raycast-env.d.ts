/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Hide World Map - Hide the world map and show a dense list of timezones instead */
  "hideWorldMap": boolean
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `timezone` command */
  export type Timezone = ExtensionPreferences & {}
  /** Preferences accessible in the `proxy` command */
  export type Proxy = ExtensionPreferences & {}
  /** Preferences accessible in the `color` command */
  export type Color = ExtensionPreferences & {
  /** Color Format - The format to copy the picked color in */
  "format": "hex" | "rgb" | "hsl"
}
  /** Preferences accessible in the `ruler` command */
  export type Ruler = ExtensionPreferences & {
  /** Drag Mode - By default: click point A and point B to measure distance */
  "dragMode": boolean
}
}

declare namespace Arguments {
  /** Arguments passed to the `timezone` command */
  export type Timezone = {}
  /** Arguments passed to the `proxy` command */
  export type Proxy = {}
  /** Arguments passed to the `color` command */
  export type Color = {}
  /** Arguments passed to the `ruler` command */
  export type Ruler = {}
}

