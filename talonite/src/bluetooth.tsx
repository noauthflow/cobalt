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
  Toast,
  showToast,
} from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import { BTDevice, connectBluetooth, disconnectBluetooth, listBluetooth, toggleBluetooth } from "./native";

type AddressedAction = "connect" | "disconnect" | "toggle";

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
  const [devices, setDevices] = useState<BTDevice[] | null>(null);
  const [loading, setLoading] = useState(true);
  // addresses with an action in flight — their rows spin
  const [busy, setBusy] = useState<Set<string>>(new Set());

  const patchDevice = useCallback((address: string, patch: Partial<BTDevice>) => {
    setDevices((prev) =>
      prev?.map((d) => (d.address === address ? { ...d, ...patch } : d)),
    );
  }, []);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setDevices((await listBluetooth()) ?? []);
    } catch (err) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not list Bluetooth devices",
        message: (err as Error).message,
      });
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
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
      {(devices ?? []).map((d) => (
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
