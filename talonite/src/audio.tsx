// audio devices — list every output/input device CoreAudio knows about and
// switch which device the machine talks through. the same property write the
// Sound pane performs, done through the native helper in swift/audio.swift.

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
import { AudioDevice, listAudio, setDefaultAudio } from "./native";

// material design 3 glyphs, shipped as svg assets — image paths resolve
// relative to the assets/ folder (same convention as the timezone maps)
const sideIcon: Record<"output" | "input", string> = {
  output: "audio-output.svg",
  input: "audio-input.svg",
};

function DeviceRow(props: {
  device: AudioDevice;
  side: "output" | "input";
  refresh: () => void;
}) {
  const device = props.device;
  const side = props.side;
  const refresh = props.refresh;
  const inUse = side === "output" ? device.isDefaultOutput : device.isDefaultInput;

  const accessories: List.Item.Accessory[] = [];
  if (device.transport !== "other") accessories.push({ tag: device.transport });
  if (side === "output" && device.volume !== null) {
    accessories.push({
      text: device.muted ? "muted" : `${Math.round(device.volume)}%`,
    });
  }

  const switchTo = async () => {
    try {
      const ok = await setDefaultAudio(side, device.id);
      if (ok) {
        await showToast({
          style: Toast.Style.Success,
          title: `${side === "output" ? "Output" : "Input"} → ${device.name}`,
        });
      } else {
        await showToast({
          style: Toast.Style.Failure,
          title: `Could not switch ${side}`,
          message: "CoreAudio refused the switch",
        });
      }
    } catch (err) {
      await showToast({
        style: Toast.Style.Failure,
        title: `Could not switch ${side}`,
        message: (err as Error).message,
      });
    }
    refresh();
  };

  return (
    <List.Item
      key={`${side}-${device.id}`}
      icon={{
        source: sideIcon[side],
        tintColor: inUse ? Color.Green : Color.SecondaryText,
      }}
      title={device.name}
      accessories={accessories}
      actions={
        <ActionPanel>
          <Action
            title={inUse ? `Already your ${side}` : `Use for ${side}`}
            icon={inUse ? Icon.Checkmark : side === "output" ? Icon.Speaker : Icon.Microphone}
            onAction={switchTo}
          />
          <Action.CopyToClipboard
            title="Copy Device Name"
            content={device.name}
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

export default function Command() {
  const [devices, setDevices] = useState<AudioDevice[] | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setDevices((await listAudio()) ?? []);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const outputs = (devices ?? []).filter((d) => d.isOutput);
  const inputs = (devices ?? []).filter((d) => d.isInput);

  return (
    <List isLoading={loading} navigationTitle="Audio Devices">
      {outputs.length > 0 ? (
        <List.Section title="Output" subtitle={`${outputs.length}`}>
          {outputs.map((d) => (
            <DeviceRow key={`o${d.id}`} device={d} side="output" refresh={refresh} />
          ))}
        </List.Section>
      ) : null}
      {inputs.length > 0 ? (
        <List.Section title="Input" subtitle={`${inputs.length}`}>
          {inputs.map((d) => (
            <DeviceRow key={`i${d.id}`} device={d} side="input" refresh={refresh} />
          ))}
        </List.Section>
      ) : null}
    </List>
  );
}
