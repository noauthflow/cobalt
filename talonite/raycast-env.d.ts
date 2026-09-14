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
}

declare namespace Arguments {
  /** Arguments passed to the `timezone` command */
  export type Timezone = {}
  /** Arguments passed to the `proxy` command */
  export type Proxy = {}
}

