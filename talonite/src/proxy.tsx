import {
  Action,
  ActionPanel,
  Clipboard,
  Color,
  Form,
  Icon,
  List,
  Toast,
  showToast,
  useNavigation,
} from "@raycast/api";
import { execSync } from "child_process";
import { useCallback, useEffect, useState } from "react";

type ProxyState = {
  enabled: boolean;
  server: string;
  port: string;
};

type NetworkState = {
  service: string;
  ssid: string;
  iface: string;
  http: ProxyState;
  https: ProxyState;
};

function run(cmd: string): string {
  try {
    return execSync(cmd, {
      encoding: "utf8",
      env: { ...process.env, PATH: "/usr/sbin:/sbin:/usr/bin:/bin" },
    }).trim();
  } catch {
    return "";
  }
}

function getDefaultInterface(): string {
  return run(
    "route -n get default 2>/dev/null | awk '/interface:/ {print $2}'",
  );
}

function getActiveService(iface: string): string {
  if (!iface) return "Wi-Fi";
  const out = run("networksetup -listnetworkserviceorder");
  const blocks = out.split(/\n\n+/);
  for (const block of blocks) {
    const nameMatch = block.match(/^\(\d+\)\s+(.+)$/m);
    const devMatch = block.match(/Device:\s*([^)]+)\)/);
    if (nameMatch && devMatch && devMatch[1].trim() === iface) {
      return nameMatch[1].trim();
    }
  }
  return "Wi-Fi";
}

function getSSID(iface: string): string {
  if (!iface) return "";
  const out = run(`networksetup -getairportnetwork "${iface}" 2>/dev/null`);
  const m = out.match(/Current Wi-Fi Network:\s*(.+)/);
  if (!m) return "";
  const name = m[1].trim();
  if (!name || /redacted/i.test(name)) return "";
  return name;
}

function getWifiPassword(ssid: string): string {
  if (!ssid) return "";
  const safe = ssid.replace(/"/g, '\\"');
  try {
    return execSync(`security find-generic-password -wa "${safe}" 2>/dev/null`, {
      encoding: "utf8",
    }).trim();
  } catch {
    return "";
  }
}

function parseProxy(info: string): ProxyState {
  return {
    enabled: /Enabled:\s*Yes/.test(info),
    server: info.match(/Server:\s*(.+)/)?.[1]?.trim() ?? "",
    port: info.match(/Port:\s*(.+)/)?.[1]?.trim() ?? "",
  };
}

function readState(): NetworkState {
  const iface = getDefaultInterface();
  const service = getActiveService(iface);
  const ssid = getSSID(iface);
  const http = parseProxy(run(`networksetup -getwebproxy "${service}"`));
  const https = parseProxy(run(`networksetup -getsecurewebproxy "${service}"`));
  return { service, ssid, iface, http, https };
}

function setHttpState(service: string, on: boolean) {
  run(`networksetup -setwebproxystate "${service}" ${on ? "on" : "off"}`);
}

function setHttpsState(service: string, on: boolean) {
  run(`networksetup -setsecurewebproxystate "${service}" ${on ? "on" : "off"}`);
}

function setHttpServer(service: string, host: string, port: string) {
  run(`networksetup -setwebproxy "${service}" "${host}" "${port}"`);
}

function setHttpsServer(service: string, host: string, port: string) {
  run(`networksetup -setsecurewebproxy "${service}" "${host}" "${port}"`);
}

function ProxyForm(props: {
  which: "http" | "https";
  service: string;
  initial: ProxyState;
  onSaved: () => void;
}) {
  const { pop } = useNavigation();
  const [host, setHost] = useState(props.initial.server);
  const [port, setPort] = useState(props.initial.port);

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save"
            onSubmit={async () => {
              if (!host || !port) {
                await showToast({
                  style: Toast.Style.Failure,
                  title: "Host and port required",
                });
                return;
              }
              if (props.which === "http")
                setHttpServer(props.service, host, port);
              else setHttpsServer(props.service, host, port);
              await showToast({
                style: Toast.Style.Success,
                title: `Saved ${props.which.toUpperCase()} proxy`,
                message: `${host}:${port}`,
              });
              props.onSaved();
              pop();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.Description
        text={`Configure ${props.which.toUpperCase()} proxy for ${props.service}. Saving also enables it.`}
      />
      <Form.TextField
        id="host"
        title="Host"
        value={host}
        onChange={setHost}
        placeholder="127.0.0.1"
      />
      <Form.TextField
        id="port"
        title="Port"
        value={port}
        onChange={setPort}
        placeholder="8080"
      />
    </Form>
  );
}

export default function Command() {
  const [state, setState] = useState<NetworkState | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(() => {
    setLoading(true);
    setState(readState());
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  const toggleOne = async (which: "http" | "https") => {
    if (!state) return;
    const current = state[which];
    const next = !current.enabled;
    if (next && !current.server) {
      await showToast({
        style: Toast.Style.Failure,
        title: `${which.toUpperCase()} host not set`,
        message: "Press ⌘E to configure host and port first",
      });
      return;
    }
    if (which === "http") setHttpState(state.service, next);
    else setHttpsState(state.service, next);
    await showToast({
      style: Toast.Style.Success,
      title: `${which.toUpperCase()} ${next ? "ON" : "OFF"}`,
    });
    refresh();
  };

  const toggleBoth = async () => {
    if (!state) return;
    const bothOn = state.http.enabled && state.https.enabled;
    const target = !bothOn;
    if (target && (!state.http.server || !state.https.server)) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Proxy host not configured",
        message: "Set host and port for HTTP and HTTPS first (⌘E)",
      });
      return;
    }
    setHttpState(state.service, target);
    setHttpsState(state.service, target);
    await showToast({
      style: Toast.Style.Success,
      title: `Both ${target ? "ON" : "OFF"}`,
    });
    refresh();
  };

  const copyWifiPassword = async () => {
    if (!state?.ssid) return;
    const pw = getWifiPassword(state.ssid);
    if (!pw) {
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not read password",
        message: "Keychain access denied or network not saved",
      });
      return;
    }
    await Clipboard.copy(pw, { concealed: true });
    await showToast({
      style: Toast.Style.Success,
      title: "Wi-Fi password copied",
      message: state.ssid,
    });
  };

  if (!state) return <List isLoading={loading} />;

  const wifiRow = (
    <List.Item
      key="wifi"
      icon={{ source: Icon.Wifi, tintColor: Color.Blue }}
      title={state.ssid || (state.iface ? "SSID hidden" : "Not connected")}
      subtitle={state.service}
      accessories={state.iface ? [{ tag: state.iface }] : []}
      actions={
        <ActionPanel>
          <Action
            title="Copy Wi-Fi Password"
            icon={Icon.Key}
            onAction={copyWifiPassword}
          />
          {state.ssid ? (
            <Action.CopyToClipboard
              title="Copy Network Name"
              content={state.ssid}
              icon={Icon.Clipboard}
              shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
            />
          ) : null}
          <Action
            title="Refresh"
            icon={Icon.ArrowClockwise}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={refresh}
          />
        </ActionPanel>
      }
    />
  );

  const proxyRow = (label: string, proxy: ProxyState, which: "http" | "https") => {
    const accessories: List.Item.Accessory[] = proxy.server
      ? [
          { tag: { value: proxy.server, color: Color.Blue } },
          { tag: { value: proxy.port || "?", color: Color.Purple } },
        ]
      : [{ text: "not configured" }];

    return (
      <List.Item
        key={which}
        icon={{
          source: proxy.enabled ? Icon.CheckCircle : Icon.Circle,
          tintColor: proxy.enabled ? Color.Green : Color.SecondaryText,
        }}
        title={label}
        subtitle={proxy.enabled ? "Enabled" : "Disabled"}
        accessories={accessories}
        actions={
          <ActionPanel>
            <Action
              title={`Toggle ${label}`}
              icon={Icon.Power}
              onAction={() => toggleOne(which)}
            />
            <Action
              title="Toggle Both"
              icon={Icon.Switch}
              shortcut={{ modifiers: ["cmd"], key: "b" }}
              onAction={toggleBoth}
            />
            <Action.Push
              title="Edit Host and Port"
              icon={Icon.Pencil}
              shortcut={{ modifiers: ["cmd"], key: "e" }}
              target={
                <ProxyForm
                  which={which}
                  service={state.service}
                  initial={proxy}
                  onSaved={refresh}
                />
              }
            />
            {proxy.server ? (
              <Action.CopyToClipboard
                title="Copy Host and Port"
                content={`${proxy.server}:${proxy.port}`}
                shortcut={{ modifiers: ["cmd"], key: "c" }}
              />
            ) : null}
            <Action
              title="Refresh"
              icon={Icon.ArrowClockwise}
              shortcut={{ modifiers: ["cmd"], key: "r" }}
              onAction={refresh}
            />
          </ActionPanel>
        }
      />
    );
  };

  return (
    <List isLoading={loading} navigationTitle="Proxy Toggle">
      <List.Section title="Network">{wifiRow}</List.Section>
      <List.Section title="Proxies">
        {proxyRow("HTTP", state.http, "http")}
        {proxyRow("HTTPS", state.https, "https")}
      </List.Section>
    </List>
  );
}
