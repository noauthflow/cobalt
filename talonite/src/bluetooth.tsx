// bluetooth devices — list paired devices with their live connection state
// and connect/disconnect/toggle them, done through the native helper in
// swift/bluetooth.swift (IOBluetooth). the first action triggers macOS's
// Bluetooth permission prompt for Raycast; grant it once and it stays
// granted across rebuilds.
//
// feedback: the row flips its icon optimistically and spins while the
// action is in flight, an animated toast tracks the attempt, and after the
// native call returns we poll the hardware — openConnection() returns long
// before the handshake finishes, so the verdict toast only fires once the
// device is *actually* connected (or gave up).

import {
  Action,
  ActionPanel,
  Color,
  Icon,
  List,
  LocalStorage,
  Toast,
  getPreferenceValues,
  showToast,
} from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import { BTDevice, connectBluetooth, disconnectBluetooth, listBluetooth, toggleBluetooth } from "./native";

type AddressedAction = "connect" | "disconnect" | "toggle";

// command preference (set in Talonite → Bluetooth Devices settings, persisted
// by Raycast): hide paired LE gadgets that can't actually connect
type BluetoothPrefs = { hideNonConnectable: boolean };
const prefs = getPreferenceValues<BluetoothPrefs>();

// material design 3 glyphs, shipped as svg assets — image paths resolve
// relative to the assets/ folder (same convention as the timezone maps).
// in flight = same glyph, tinted yellow; connected = green; idle = grey
const kindIcon: Record<BTDevice["kind"], string> = {
  keyboard: "bt-keyboard.svg",
  mouse: "bt-mouse.svg",
  unknown: "bt-bluetooth.svg",
};

function perform(action: AddressedAction, address: string): Promise<boolean | null> {
  switch (action) {
    case "connect":
      return connectBluetooth(address);
    case "disconnect":
      return disconnectBluetooth(address);
    default:
      return toggleBluetooth(address);
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// last-known device list, kept in a module var so re-opens within the same
// raycast session paint synchronously (the js context survives between
// opens), and mirrored to LocalStorage so even a cold session starts from
// real data instead of an empty list. the native spawn still runs on every
// open — but in the background, only patching what actually changed.
const DEVICES_KEY = "talonite/bt-devices";
let memoryDevices: BTDevice[] | null = null;

// the past-tense verb each action resolves to, for toasts
function verb(action: AddressedAction): string {
  switch (action) {
    case "connect":
      return "connected";
    case "disconnect":
      return "disconnected";
    default:
      return "toggled";
  }
}

export default function Command() {
  // starts from the last-known list (memory first, LocalStorage if we get
  // there before the spawn finishes) — never from an empty list
  const [devices, setDevices] = useState<BTDevice[] | null>(memoryDevices);
  const [loading, setLoading] = useState(memoryDevices === null);
  // addresses with an action in flight — their rows spin
  const [busy, setBusy] = useState<Set<string>>(new Set());

  const patchDevice = useCallback((address: string, patch: Partial<BTDevice>) => {
    setDevices((prev) => prev?.map((d) => (d.address === address ? { ...d, ...patch } : d)) ?? prev);
  }, []);

  const apply = useCallback((fresh: BTDevice[]) => {
    // skip the re-render entirely when nothing changed — swapping the state
    // object for an identical one re-mounts icons visibly
    setDevices((prev) => {
      const same =
        prev?.length === fresh.length &&
        prev.every((p, i) => {
          const f = fresh[i];
          return (
            p.address === f.address &&
            p.isConnected === f.isConnected &&
            p.kind === f.kind &&
            p.isFavorite === f.isFavorite &&
            p.name === f.name
          );
        });
      if (same) return prev;
      memoryDevices = fresh;
      LocalStorage.setItem(DEVICES_KEY, JSON.stringify(fresh)).catch(() => {});
      return fresh;
    });
  }, []);

  const refresh = useCallback(async () => {
    try {
      const fresh = await listBluetooth();
      if (fresh) apply(fresh);
    } catch (err) {
      // cold start with nothing to show — surface the failure loudly;
      // background refreshes just keep the last-known list
      if (memoryDevices === null) {
        await showToast({
          style: Toast.Style.Failure,
          title: "Could not list Bluetooth devices",
          message: (err as Error).message,
        });
      }
    } finally {
      setLoading(false);
    }
  }, [apply]);

  useEffect(() => {
    if (memoryDevices !== null) {
      // instant paint already on screen — just reconcile in the background
      refresh();
      return;
    }
    // cold session: LocalStorage read is ~1ms vs ~100ms for the spawn, so
    // paint from it first, then let refresh() quietly replace it if changed
    (async () => {
      try {
        const raw = await LocalStorage.getItem<string>(DEVICES_KEY);
        if (raw && memoryDevices === null) {
          memoryDevices = JSON.parse(raw) as BTDevice[];
          setDevices(memoryDevices);
          setLoading(false);
        }
      } catch {
        // no cache — refresh() alone will fill the list
      }
      refresh();
    })();
  }, [refresh]);

  const act = useCallback(
    async (device: BTDevice, action: AddressedAction) => {
      const address = device.address;
      // target state: toggle resolves against live hardware at call time
      const willConnect = action === "connect" ? true : action === "disconnect" ? false : !device.isConnected;

      const toast = await showToast({
        style: Toast.Style.Animated,
        title: `${willConnect ? "Connecting to" : "Disconnecting"} ${device.name}…`,
      });

      // no optimistic flip — the icon shows the shimmer until the hardware
      // actually agrees; state stays honest until the poll confirms
      setBusy((prev) => new Set(prev).add(address));

      let failure: string | null = null;
      try {
        const ok = await perform(action, address);
        if (!ok) failure = "the system refused the request";
      } catch (err) {
        failure = (err as Error).message || "native helper failed";
      }

      // the call returns before the handshake does — poll the hardware
      // until it agrees (or stop asking after ~3s) before passing verdict
      let settled: boolean | null = null;
      for (let attempt = 0; attempt < 3 && failure === null; attempt++) {
        await sleep(1100);
        try {
          const fresh = (await listBluetooth())?.find((d) => d.address === address);
          if (fresh) {
            patchDevice(address, { isConnected: fresh.isConnected });
            settled = fresh.isConnected;
            if (settled === willConnect) break;
          }
        } catch {
          // transient poll failure — keep the optimistic state, retry
        }
      }

      setBusy((prev) => {
        const next = new Set(prev);
        next.delete(address);
        return next;
      });

      if (failure !== null) {
        toast.style = Toast.Style.Failure;
        toast.title = `Could not ${action} ${device.name}`;
        toast.message =
          failure.includes("not allowed") || failure.includes("denied")
            ? "Bluetooth permission denied — grant Raycast access and retry"
            : failure;
        return;
      }

      if (settled === willConnect || settled === null) {
        toast.style = Toast.Style.Success;
        toast.title = `${device.name} ${verb(action)}`;
      } else {
        toast.style = Toast.Style.Failure;
        toast.title = `${device.name} didn't ${action}`;
        toast.message = "Device unreachable or asleep — wake it up and try again";
      }
    },
    [patchDevice],
  );

  const busyRow = (device: BTDevice, action: AddressedAction) => act(device, action);

  return (
    <List isLoading={loading} navigationTitle="Bluetooth Devices">
      {(devices ?? [])
        .filter((d) => !prefs.hideNonConnectable || d.isConnectable)
        .map((d) => (
          <DeviceRow
            key={d.address}
            device={d}
            busy={busy.has(d.address)}
            onAction={busyRow}
            refresh={refresh}
          />
        ))}
    </List>
  );
}

function DeviceRow(props: {
  device: BTDevice;
  busy: boolean;
  onAction: (device: BTDevice, action: AddressedAction) => void;
  refresh: () => void;
}) {
  const device = props.device;

  const icon = props.busy
    ? { source: kindIcon[device.kind], tintColor: Color.Yellow }
    : {
        source: kindIcon[device.kind],
        tintColor: device.isConnected ? Color.Green : Color.SecondaryText,
      };

  const accessories: List.Item.Accessory[] = [];
  if (device.isFavorite) accessories.push({ icon: Icon.Star, tooltip: "Favorite" });
  // the identifier — the device's address — is the right-hand accessory;
  // connection state lives entirely in the icon's tint
  accessories.push({ text: device.address });

  return (
    <List.Item
      key={device.address}
      icon={icon}
      title={device.name}
      accessories={accessories}
      isLoading={props.busy}
      actions={
        <ActionPanel>
          {device.isConnected ? (
            <Action
              title="Disconnect"
              icon={Icon.Power}
              onAction={() => props.onAction(device, "disconnect")}
            />
          ) : (
            <Action
              title="Connect"
              icon={Icon.Bluetooth}
              onAction={() => props.onAction(device, "connect")}
            />
          )}
          <Action
            title="Toggle Connection"
            icon={Icon.Switch}
            shortcut={{ modifiers: ["cmd"], key: "t" }}
            onAction={() => props.onAction(device, "toggle")}
          />
          <Action.CopyToClipboard
            title="Copy MAC Address"
            content={device.address}
            shortcut={{ modifiers: ["cmd"], key: "c" }}
          />
          <Action
            title="Refresh"
            icon={Icon.ArrowClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={props.refresh}
          />
        </ActionPanel>
      }
    />
  );
}
