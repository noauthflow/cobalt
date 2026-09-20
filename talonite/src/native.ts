// bridge to the native helpers in swift/, compiled by build-native.sh into
// assets/compiled_raycast_swift/. same calling convention raycast's own
// swift packaging generates: argv = [command, ...json-encoded args], result
// as JSON on stdout, null when nothing was produced (e.g. cancelled).

import { environment } from "@raycast/api";
import { spawn } from "child_process";
import { chmod } from "fs/promises";
import { join } from "path";

export type PickedColor = {
  colorSpace: string;
  red: number;
  green: number;
  blue: number;
  alpha: number;
};

export type AudioDevice = {
  id: number;
  uid: string;
  name: string;
  transport: string;
  isOutput: boolean;
  isInput: boolean;
  isDefaultOutput: boolean;
  isDefaultInput: boolean;
  isDefaultSystem: boolean;
  // 0-100, output side only; null when the device has no master volume
  volume: number | null;
  muted: boolean;
};

export type BTDevice = {
  name: string;
  address: string;
  isConnected: boolean;
  isFavorite: boolean;
  kind: "keyboard" | "mouse" | "unknown";
};

export class NativeError extends Error {
  stdout?: string;
  stderr?: string;
}

function runNative<T>(
  binary: string,
  command: string,
  ...args: unknown[]
): Promise<T | null> {
  const path = join(environment.assetsPath, "compiled_raycast_swift", binary);
  return new Promise((resolve, reject) => {
    chmod(path, 0o755).catch((err) => reject(new NativeError(err.message)));

    const child = spawn(path, [
      command,
      ...args.map((a) =>
        JSON.stringify(a, (_k, v) => (v === undefined ? null : v)),
      ),
    ]);
    const stdout: string[] = [];
    const stderr: string[] = [];
    child.stdout?.on("data", (d) => stdout.push(d.toString()));
    child.stderr?.on("data", (d) => stderr.push(d.toString()));

    child.on("exit", (code) => {
      if (code === 0) {
        const out = stdout.join("").trim();
        if (!out) {
          resolve(null);
          return;
        }
        try {
          resolve(JSON.parse(out) as T);
        } catch (err) {
          reject(
            new NativeError(
              `failed to parse result: ${(err as Error).message}`,
            ),
          );
        }
      } else {
        const error = new NativeError(
          stderr.join("").trim() || stdout.join("").trim() || "no output",
        );
        error.stdout = stdout.join("").trim();
        error.stderr = stderr.join("").trim();
        reject(error);
      }
    });

    child.on("error", (err) => reject(new NativeError(err.message)));
  });
}

export function pickColor(): Promise<PickedColor | null> {
  return runNative("color-picker", "pickColor");
}

export function measureDistance(dragMode: boolean): Promise<string | null> {
  return runNative("Ruler", "measureDistance", dragMode);
}

export function listAudio(): Promise<AudioDevice[] | null> {
  return runNative("audio", "listDevices");
}

export function setDefaultAudio(
  direction: "output" | "input" | "system",
  id: number,
): Promise<boolean | null> {
  return runNative("audio", "setDefaultDevice", { direction, id });
}

export function listBluetooth(): Promise<BTDevice[] | null> {
  return runNative("bluetooth", "listDevices");
}

export function connectBluetooth(address: string): Promise<boolean | null> {
  return runNative("bluetooth", "connectDevice", { address });
}

export function disconnectBluetooth(address: string): Promise<boolean | null> {
  return runNative("bluetooth", "disconnectDevice", { address });
}

export function toggleBluetooth(address: string): Promise<boolean | null> {
  return runNative("bluetooth", "toggleDevice", { address });
}
