// rc-timezone — pinned timezones for any instant.
//
// full parity with the oracle (raycast-timezone-converter v1.0.4):
// zone-scoped custom time, manual reorder, world map — plus extras the
// oracle lacks (relative offsets, day-shift arrows, copy, live tick).
//
// zero network, zero filesystem, zero spawns, zero eval, zero permissions.
// IANA conversion is the platform Intl API; zone lists come from the OS's
// own ICU database; state is Raycast preferences storage.

import {
  Action,
  ActionPanel,
  Alert,
  Clipboard,
  Detail,
  Form,
  Icon,
  List,
  Toast,
  confirmAlert,
  getPreferenceValues,
  showToast,
  useNavigation,
} from "@raycast/api";
import { useCachedState } from "@raycast/utils";
import { useEffect, useMemo, useState } from "react";

// ---------------------------------------------------------------- zones

const ALL_ZONES: string[] = [
  "UTC",
  ...(Intl as any).supportedValuesOf("timeZone"),
];
const LOCAL_TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
const ALL_ZONES_SORTED = [
  LOCAL_TZ,
  ...ALL_ZONES.filter((z) => z !== LOCAL_TZ).sort(),
];
// day shift vs local: 1 = their day is ahead, -1 = behind, 0 = same day
function dayShift(tz: string, date: Date): -1 | 0 | 1 {
  const enCA = (tz: string) =>
    new Intl.DateTimeFormat("en-CA", { timeZone: tz }).format(date); // YYYY-MM-DD
  const here = enCA(LOCAL_TZ);
  const there = enCA(tz);
  return here === there ? 0 : there > here ? 1 : -1;
}

// ---------------------------------------------------- search: fuzzy + abbrev
//
// the zone menu is 400+ entries — nobody scrolls that. search understands:
//   abbreviations   "nyc" "tyo" "us" "uk" (city + country codes below)
//   substrings      "york" "tokyo"
//   subsequences    "nyk" → New_York (in order, with bonuses)
//   typos           "wunited stets" → United States (levenshtein, ranked)

const CITY_ALIASES: Record<string, string> = {
  nyc: "America/New_York",
  dc: "America/New_York",
  bos: "America/New_York",
  phi: "America/New_York",
  atl: "America/New_York",
  mia: "America/New_York",
  tor: "America/Toronto",
  yyz: "America/Toronto",
  chi: "America/Chicago",
  dfw: "America/Chicago",
  den: "America/Denver",
  phx: "America/Phoenix",
  la: "America/Los_Angeles",
  lax: "America/Los_Angeles",
  sf: "America/Los_Angeles",
  sfo: "America/Los_Angeles",
  sea: "America/Los_Angeles",
  pdx: "America/Los_Angeles",
  yvr: "America/Vancouver",
  mex: "America/Mexico_City",
  gru: "America/Sao_Paulo",
  sao: "America/Sao_Paulo",
  bue: "America/Argentina/Buenos_Aires",
  scl: "America/Santiago",
  lon: "Europe/London",
  ldn: "Europe/London",
  lhr: "Europe/London",
  dub: "Europe/Dublin",
  par: "Europe/Paris",
  ber: "Europe/Berlin",
  muc: "Europe/Berlin",
  rom: "Europe/Rome",
  mil: "Europe/Rome",
  mad: "Europe/Madrid",
  bc: "Europe/Madrid",
  lis: "Europe/Lisbon",
  ams: "Europe/Amsterdam",
  bru: "Europe/Brussels",
  zur: "Europe/Zurich",
  vie: "Europe/Vienna",
  bru: "Europe/Brussels",
  cph: "Europe/Copenhagen",
  sto: "Europe/Stockholm",
  osl: "Europe/Oslo",
  hel: "Europe/Helsinki",
  athen: "Europe/Athens",
  ist: "Europe/Istanbul",
  msq: "Europe/Moscow",
  tyo: "Asia/Tokyo",
  tok: "Asia/Tokyo",
  hnd: "Asia/Tokyo",
  sel: "Asia/Seoul",
  icn: "Asia/Seoul",
  pek: "Asia/Shanghai",
  sha: "Asia/Shanghai",
  hkg: "Asia/Hong_Kong",
  tpe: "Asia/Taipei",
  sin: "Asia/Singapore",
  kul: "Asia/Kuala_Lumpur",
  bkk: "Asia/Bangkok",
  sgn: "Asia/Ho_Chi_Minh",
  mnl: "Asia/Manila",
  jak: "Asia/Jakarta",
  del: "Asia/Kolkata",
  bom: "Asia/Kolkata",
  blr: "Asia/Kolkata",
  ktm: "Asia/Kathmandu",
  dxb: "Asia/Dubai",
  riy: "Asia/Riyadh",
  tbs: "Asia/Tbilisi",
  syd: "Australia/Sydney",
  mel: "Australia/Melbourne",
  bri: "Australia/Brisbane",
  per: "Australia/Perth",
  adl: "Australia/Adelaide",
  akl: "Pacific/Auckland",
  wlg: "Pacific/Auckland",
  hnl: "Pacific/Honolulu",
};

// country codes → their zones (curated — the ones people actually type)
const COUNTRY_ZONES: Record<string, string[]> = {
  us: [
    "America/New_York",
    "America/Chicago",
    "America/Denver",
    "America/Phoenix",
    "America/Los_Angeles",
    "America/Anchorage",
    "Pacific/Honolulu",
  ],
  usa: [
    "America/New_York",
    "America/Chicago",
    "America/Denver",
    "America/Phoenix",
    "America/Los_Angeles",
    "America/Anchorage",
    "Pacific/Honolulu",
  ],
  uk: ["Europe/London"],
  gb: ["Europe/London"],
  ie: ["Europe/Dublin"],
  fr: ["Europe/Paris"],
  de: ["Europe/Berlin"],
  it: ["Europe/Rome"],
  es: ["Europe/Madrid"],
  pt: ["Europe/Lisbon"],
  nl: ["Europe/Amsterdam"],
  be: ["Europe/Brussels"],
  ch: ["Europe/Zurich"],
  at: ["Europe/Vienna"],
  se: ["Europe/Stockholm"],
  no: ["Europe/Oslo"],
  dk: ["Europe/Copenhagen"],
  fi: ["Europe/Helsinki"],
  pl: ["Europe/Warsaw"],
  cz: ["Europe/Prague"],
  gr: ["Europe/Athens"],
  ro: ["Europe/Bucharest"],
  hu: ["Europe/Budapest"],
  tr: ["Europe/Istanbul"],
  ua: ["Europe/Kyiv"],
  ru: ["Europe/Moscow", "Asia/Yekaterinburg", "Asia/Vladivostok"],
  il: ["Asia/Jerusalem"],
  ae: ["Asia/Dubai"],
  sa: ["Asia/Riyadh"],
  qa: ["Asia/Qatar"],
  eg: ["Africa/Cairo"],
  za: ["Africa/Johannesburg"],
  ng: ["Africa/Lagos"],
  ke: ["Africa/Nairobi"],
  ma: ["Africa/Casablanca"],
  in: ["Asia/Kolkata"],
  pk: ["Asia/Karachi"],
  bd: ["Asia/Dhaka"],
  lk: ["Asia/Colombo"],
  np: ["Asia/Kathmandu"],
  cn: ["Asia/Shanghai", "Asia/Urumqi"],
  jp: ["Asia/Tokyo"],
  kr: ["Asia/Seoul"],
  hk: ["Asia/Hong_Kong"],
  tw: ["Asia/Taipei"],
  sg: ["Asia/Singapore"],
  my: ["Asia/Kuala_Lumpur"],
  th: ["Asia/Bangkok"],
  vn: ["Asia/Ho_Chi_Minh"],
  ph: ["Asia/Manila"],
  id: ["Asia/Jakarta", "Asia/Makassar", "Asia/Jayapura"],
  au: [
    "Australia/Sydney",
    "Australia/Melbourne",
    "Australia/Brisbane",
    "Australia/Adelaide",
    "Australia/Perth",
    "Australia/Darwin",
  ],
  nz: ["Pacific/Auckland"],
  fj: ["Pacific/Fiji"],
  ca: [
    "America/Toronto",
    "America/Vancouver",
    "America/Edmonton",
    "America/Winnipeg",
    "America/Halifax",
    "America/St_Johns",
  ],
  br: [
    "America/Sao_Paulo",
    "America/Recife",
    "America/Manaus",
    "America/Rio_Branco",
  ],
  ar: ["America/Argentina/Buenos_Aires"],
  cl: ["America/Santiago"],
  pe: ["America/Lima"],
  co: ["America/Bogota"],
  mx: ["America/Mexico_City", "America/Tijuana"],
  cu: ["America/Havana"],
};

// zone → country code (inverted from COUNTRY_ZONES) → English country name
const ZONE_COUNTRY: Record<string, string> = {};
for (const [code, list] of Object.entries(COUNTRY_ZONES)) {
  for (const tz of list) if (!(tz in ZONE_COUNTRY)) ZONE_COUNTRY[tz] = code;
}
const REGION_NAMES = new Intl.DisplayNames(["en"], { type: "region" });
function regionName(tz: string): string {
  const code = ZONE_COUNTRY[tz];
  if (!code) return "";
  try {
    return REGION_NAMES.of(code.toUpperCase()) ?? "";
  } catch {
    return "";
  }
}

// normalize for matching: lowercase, separators → spaces, squashed
function norm(s: string): string {
  return s
    .toLowerCase()
    .replaceAll(/[/_.·\-]/g, " ")
    .replaceAll(/\s+/g, " ")
    .trim();
}

// subsequence score with consecutive + word-start bonuses (null = no match)
function subsequence(q: string, s: string): number | null {
  let score = 0,
    si = 0,
    streak = 0;
  for (const qc of q) {
    const idx = s.indexOf(qc, si);
    if (idx === -1) return null;
    if (idx === si && si > 0) {
      streak++;
      score += 2 + streak;
    } else {
      streak = 0;
      score += 1;
    }
    if (idx === 0 || s[idx - 1] === " ") score += 3;
    si = idx + 1;
  }
  return score - (s.length - q.length) * 0.05; // prefer shorter targets
}

// bounded levenshtein — early exit once the row minimum passes cap
function lev(a: string, b: string, cap: number): number {
  if (Math.abs(a.length - b.length) > cap) return cap + 1;
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    let rowMin = i;
    for (let j = 1; j <= b.length; j++) {
      const v = Math.min(
        prev[j] + 1,
        cur[j - 1] + 1,
        prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1),
      );
      cur.push(v);
      if (v < rowMin) rowMin = v;
    }
    if (rowMin > cap) return cap + 1;
    prev = cur;
  }
  return prev[b.length];
}

// per-word matching: each query word vs each field word — catches multi-word
// typos ("wunited stets" → "united states") that whole-string lev misses
function wordLev(q: string, field: string): number {
  const qw = q.split(" ");
  const fw = field.split(" ");
  let total = 0;
  for (const a of qw) {
    let best = 99;
    const cap = a.length <= 4 ? 1 : 2;
    for (const b of fw) {
      const d = lev(a, b, cap);
      if (d < best) best = d;
      if (best === 0) break;
    }
    if (best === 99) return 99; // a query word matched nothing — bail
    total += best;
  }
  return total;
}

// the whole search: alias codes first, then substring > subsequence > typo
export function searchZones(query: string, exclude: string[]): string[] {
  const q = norm(query);
  if (!q) return ALL_ZONES_SORTED.slice(0, 50);
  const compact = q.replaceAll(" ", "");
  const out: { tz: string; score: number }[] = [];
  const seen = new Set<string>();
  const push = (tz: string, score: number) => {
    if (seen.has(tz) || exclude.includes(tz)) return;
    seen.add(tz);
    out.push({ tz, score });
  };

  // exact alias codes jump the queue
  if (CITY_ALIASES[compact]) push(CITY_ALIASES[compact], 10_000);
  if (COUNTRY_ZONES[compact])
    COUNTRY_ZONES[compact].forEach((tz, i) => push(tz, 9_000 - i));

  const cap = q.length <= 3 ? 0 : q.length <= 8 ? 1 : 2;
  for (const tz of ALL_ZONES) {
    if (exclude.includes(tz)) continue;
    const fields = [
      norm(tz),
      norm(zoneTitle(tz)),
      norm(tz.split("/").pop()!.replaceAll("_", " ")),
      norm(tz.split("/")[0].replaceAll("_", " ")),
      norm(regionName(tz)),
    ];
    let best = 0;
    for (const field of fields) {
      if (!field) continue;
      if (field === q) {
        best = Math.max(best, 5_000);
        continue;
      }
      const pos = field.indexOf(q);
      if (pos !== -1) {
        const s = 1_000 - pos * 10 - (field.length - q.length) * 0.5;
        if (s > best) best = s;
      }
      const sub = subsequence(q, field);
      if (sub !== null && sub > best) best = sub;
      if (q.length >= 4) {
        const d = lev(q, field, cap);
        if (d <= cap) {
          const s = 2_000 - d * 400 - field.length * 0.1;
          if (s > best) best = s;
        }
        const wd = wordLev(q, field);
        if (wd <= 3) {
          // per-word caps already bound each word individually
          const s = 1_500 - wd * 300 - field.length * 0.1;
          if (s > best) best = s;
        }
      }
    }
    if (best > 0) push(tz, best);
  }
  return out
    .sort((a, b) => b.score - a.score)
    .slice(0, 50)
    .map((r) => r.tz);
}

interface Preferences {
  hideWorldMap: boolean;
}
const preferences = getPreferenceValues<Preferences>();

function zoneTitle(tz: string) {
  return tz.replaceAll("_", " ").replaceAll("/", " · ");
}

// GMT offset string via Intl — "GMT+9:30" style, correct for `date`
function offsetString(tz: string, date: Date): string {
  try {
    const part = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      timeZoneName: "shortOffset",
    })
      .formatToParts(date)
      .find((p) => p.type === "timeZoneName");
    return part?.value ?? "";
  } catch {
    return "";
  }
}

// offset in minutes for the exact instant (DST-aware: the zone's offset
// varies through the year, so this is a function of the instant)
function offsetMinutes(tz: string, date: Date): number {
  try {
    const s =
      new Intl.DateTimeFormat("en-US", {
        timeZone: tz,
        timeZoneName: "longOffset",
      })
        .formatToParts(date)
        .find((p) => p.type === "timeZoneName")?.value ?? "";
    const m = s.match(/GMT([+-])(\d{1,2})(?::(\d{2}))?/);
    if (!m) return 0;
    const sign = m[1] === "-" ? -1 : 1;
    return sign * (parseInt(m[2]) * 60 + (m[3] ? parseInt(m[3]) : 0));
  } catch {
    return 0;
  }
}

// wall-clock components of `date` as seen in tz
function wallIn(tz: string, date: Date) {
  const p = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(date);
  const get = (t: string) =>
    parseInt(p.find((x) => x.type === t)?.value ?? "0", 10);
  return {
    year: get("year"),
    month: get("month"),
    day: get("day"),
    hour: get("hour") % 24, // en-US can emit "24" for midnight
    minute: get("minute"),
  };
}

// interpret wall-clock components AS a wall time in tz → instant.
// two-pass: build a UTC guess, read the zone's offset at it, correct.
function instantFromWall(
  c: { year: number; month: number; day: number; hour: number; minute: number },
  tz: string,
): Date {
  const asUTC = Date.UTC(c.year, c.month - 1, c.day, c.hour, c.minute);
  const guess = new Date(asUTC);
  const off = offsetMinutes(tz, guess);
  return new Date(asUTC - off * 60_000);
}

// "+2:30h ahead of you" / "1h behind" — relative to local, at this instant
function relativeLabel(tz: string, date: Date): string {
  const delta = offsetMinutes(tz, date) - offsetMinutes(LOCAL_TZ, date);
  if (delta === 0) return "same as you";
  const sign = delta > 0 ? "+" : "−";
  const abs = Math.abs(delta);
  const h = Math.floor(abs / 60);
  const m = abs % 60;
  const core =
    h === 0
      ? `${m}m`
      : m === 0
        ? `${h}h`
        : `${h}:${String(m).padStart(2, "0")}h`;
  return `${sign}${core} ${delta > 0 ? "ahead" : "behind"}`;
}

function timeIn(tz: string, date: Date): string {
  try {
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: tz,
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    }).format(date);
  } catch {
    return "—";
  }
}
function dateIn(tz: string, date: Date): string {
  try {
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: tz,
      weekday: "short",
      day: "2-digit",
      month: "short",
    }).format(date);
  } catch {
    return "";
  }
}

// the oracle's map asset naming: timezones/UTC{±n[.5]}.png — 0 has no suffix
function mapAsset(tz: string, date: Date): string | null {
  const off = offsetMinutes(tz, date) / 60;
  const dec = off === 0 ? "" : off > 0 ? `+${off}` : `${off}`;
  const name = `timezones/UTC${dec}.png`;
  return ASSET_OFFSETS.has(`UTC${dec}`) ? name : null;
}
// which map assets exist (from the oracle's 25 bundled maps)
const ASSET_OFFSETS = new Set([
  "UTC",
  "UTC-1",
  "UTC-2",
  "UTC-3",
  "UTC-4",
  "UTC-5",
  "UTC-6",
  "UTC-7",
  "UTC-8",
  "UTC-9",
  "UTC-10",
  "UTC-11",
  "UTC-12",
  "UTC+1",
  "UTC+2",
  "UTC+3",
  "UTC+3.5",
  "UTC+4",
  "UTC+4.5",
  "UTC+5",
  "UTC+5.5",
  "UTC+6",
  "UTC+7",
  "UTC+8",
  "UTC+9",
]);

// ------------------------------------------------------------ custom time

function CustomTime({
  initial,
  onPick,
}: {
  initial: Date;
  onPick: (d: Date) => void;
}) {
  const { pop } = useNavigation();
  // wall time as displayed in the chosen zone
  const [zone, setZone] = useState(LOCAL_TZ);
  const [wall, setWall] = useState(() => {
    const w = wallIn(zone, initial);
    return new Date(w.year, w.month - 1, w.day, w.hour, w.minute);
  });

  // switching zone keeps the wall clock — that's the oracle's behavior
  function changeZone(newZone: string) {
    const w = wallIn(zone, wall);
    const asLocal = new Date(w.year, w.month - 1, w.day, w.hour, w.minute);
    const next = instantFromWall(newZone, w);
    setZone(newZone);
    setWall(asLocal); // picker keeps showing the same wall time
    void next; // (instant is recomputed on submit from wall + zone)
  }

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Set Reference Time"
            onSubmit={() => {
              // the DatePicker's value carries the picked wall time as local
              // components; reinterpret those components IN the chosen zone
              const w = wallIn(LOCAL_TZ, wall);
              const instant = instantFromWall(zone, w);
              onPick(instant);
              void showToast({
                style: Toast.Style.Success,
                title: `Reference set in ${zoneTitle(zone)}`,
              });
              pop();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.DatePicker
        id="when"
        title="Time"
        value={wall}
        onChange={(d) => d && setWall(d)}
      />
      <Form.Dropdown
        id="zone"
        title="In timezone"
        value={zone}
        onChange={changeZone}
      >
        {ALL_ZONES_SORTED.map((tz) => (
          <Form.Dropdown.Item
            key={tz}
            value={tz}
            title={`${zoneTitle(tz)}  (${offsetString(tz, new Date())})`}
          />
        ))}
      </Form.Dropdown>
      <Form.Description text="Enter a wall time as it reads in the chosen timezone — every pinned zone re-renders at that instant. Clear the custom time to go back to now." />
    </Form>
  );
}

// --------------------------------------------------------------- reorder

function Reorder({
  zones,
  onSave,
}: {
  zones: string[];
  onSave: (z: string[]) => void;
}) {
  const { pop } = useNavigation();
  const [list, setList] = useState(zones);

  function commit(next: string[]) {
    setList(next);
    onSave(next);
  }
  function move(index: number, delta: -1 | 1) {
    const to = index + delta;
    if (to < 0 || to >= list.length) return;
    const next = [...list];
    [next[index], next[to]] = [next[to], next[index]];
    commit(next);
  }
  function remove(index: number) {
    const next = [...list];
    next.splice(index, 1);
    commit(next);
  }

  return (
    <List navigationTitle="Reorder Timezones">
      {list.map((tz, i) => (
        <List.Item
          key={tz}
          title={zoneTitle(tz)}
          icon={Icon.Clock}
          actions={
            <ActionPanel>
              {i > 0 && (
                <Action
                  title="Move Up"
                  icon={Icon.ChevronUp}
                  shortcut={{ modifiers: ["cmd", "opt"], key: "arrowUp" }}
                  onAction={() => move(i, -1)}
                />
              )}
              {i < list.length - 1 && (
                <Action
                  title="Move Down"
                  icon={Icon.ChevronDown}
                  shortcut={{ modifiers: ["cmd", "opt"], key: "arrowDown" }}
                  onAction={() => move(i, 1)}
                />
              )}
              <Action
                title="Remove Timezone"
                icon={Icon.Trash}
                style={Action.Style.Destructive}
                shortcut={{ modifiers: ["ctrl"], key: "x" }}
                onAction={() =>
                  confirmAlert({
                    title: `Remove "${zoneTitle(tz)}"?`,
                    primaryAction: {
                      title: "Remove",
                      style: Alert.ActionStyle.Destructive,
                      onAction: () => remove(i),
                    },
                  })
                }
              />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}

// ------------------------------------------------------------ pin search

function PinSearch({
  pinned,
  onPin,
}: {
  pinned: string[];
  onPin: (tz: string) => void;
}) {
  const { pop } = useNavigation();
  const [text, setText] = useState("");
  const at = useMemo(() => new Date(), []);
  const results = useMemo(() => searchZones(text, []), [text]); // pinned zones stay visible, marked below
  return (
    <List
      navigationTitle="Pin Timezone"
      searchText={text}
      onSearchTextChange={setText}
      filtering={false} // our own fuzzy, not Raycast's
      searchBarPlaceholder="nyc · us · tokyo · wunited stets…"
    >
      {results.length === 0 && (
        <List.EmptyView
          title="No matches"
          description="Try a city code, country code, or part of a name"
        />
      )}
      {results.map((tz) => {
        const alreadyPinned = pinned.includes(tz);
        return (
          <List.Item
            key={tz}
            icon={{
              source: alreadyPinned ? Icon.CheckCircle : Icon.Circle,
              tintColor: alreadyPinned ? "#CA8A04" : "#99947F",
            }}
            title={zoneTitle(tz)}
            subtitle={offsetString(tz, at)}
            accessories={[
              { text: regionName(tz) },
              alreadyPinned
                ? { tag: { value: "pinned", color: "#CA8A04" } }
                : { tag: timeIn(tz, at) },
            ]}
            actions={
              <ActionPanel>
                {alreadyPinned ? (
                  <Action
                    title={`Unpin ${zoneTitle(tz)}`}
                    icon={Icon.Minus}
                    onAction={() => onPin(tz)}
                  />
                ) : (
                  <Action
                    title={`Pin ${zoneTitle(tz)}`}
                    icon={Icon.Plus}
                    onAction={() => {
                      onPin(tz);
                      pop();
                    }}
                  />
                )}
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}

// ------------------------------------------------------------- command

export default function Command() {
  const [zones, setZones] = useCachedState<string[]>("pinned-zones", ["UTC"]);
  const [ref, setRef] = useState<Date | null>(null); // null = now
  const [now, setNow] = useState(() => new Date());
  const { push } = useNavigation();

  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 10_000);
    return () => clearInterval(t);
  }, []);

  const at = ref ?? now;
  const isCustom = ref !== null;

  const rows = useMemo(
    () =>
      zones.map((tz) => ({
        tz,
        offset: offsetString(tz, at),
        time: timeIn(tz, at),
        date: dateIn(tz, at),
        rel: relativeLabel(tz, at),
        shift: dayShift(tz, at),
      })),
    [zones, at],
  );

  function toggle(tz: string) {
    setZones(
      zones.includes(tz) ? zones.filter((z) => z !== tz) : [...zones, tz],
    );
  }

  function pickCustom() {
    push(<CustomTime initial={at} onPick={setRef} />);
  }

  function pinActions() {
    return (
      <ActionPanel>
        <Action.Push
          title="Pin Timezone"
          icon={Icon.Globe}
          shortcut={{ modifiers: ["cmd"], key: "p" }}
          target={<PinSearch pinned={zones} onPin={(tz) => toggle(tz)} />}
        />
        <Action
          title={isCustom ? "Back to Now" : "Set Custom Time"}
          icon={Icon.Clock}
          shortcut={
            isCustom
              ? { modifiers: ["cmd"], key: "0" }
              : { modifiers: ["cmd"], key: "t" }
          }
          onAction={isCustom ? () => setRef(null) : pickCustom}
        />
        {zones.length > 1 && (
          <Action
            title="Reorder Timezones"
            icon={Icon.Switch}
            shortcut={{ modifiers: ["cmd"], key: "r" }}
            onAction={() => push(<Reorder zones={zones} onSave={setZones} />)}
          />
        )}
        {zones.length > 0 && (
          <Action
            title="Remove All"
            icon={Icon.Trash}
            style={Action.Style.Destructive}
            shortcut={{ modifiers: ["ctrl"], key: "x" }}
            onAction={() =>
              confirmAlert({
                title: "Remove all pinned timezones?",
                primaryAction: {
                  title: "Remove All",
                  style: Alert.ActionStyle.Destructive,
                  onAction: () => setZones([]),
                },
              })
            }
          />
        )}
      </ActionPanel>
    );
  }

  // world-map view (the oracle's default): a Detail with the day/night map
  // for the reference offset + every pinned zone as a tag
  if (!preferences.hideWorldMap) {
    const map = mapAsset(LOCAL_TZ, at);
    const header = `# ${isCustom ? "Custom time" : "Local time"}\n## ${timeIn(LOCAL_TZ, at)} ${offsetString(LOCAL_TZ, at)} — ${zoneTitle(LOCAL_TZ)}\n${map ? `![world map](${map})\n` : ""}`;
    return (
      <Detail
        navigationTitle={isCustom ? `Ref: ${at.toLocaleString()}` : "Timezones"}
        markdown={header}
        actions={pinActions()}
        metadata={
          <Detail.Metadata>
            {zones.length === 0 && (
              <Detail.Metadata.Label
                title="No timezones pinned"
                text="⌘P to pin one"
              />
            )}
            {rows.map((r) => (
              <Detail.Metadata.TagList
                key={r.tz}
                title={`${zoneTitle(r.tz)} (${r.offset})`}
              >
                <Detail.Metadata.TagList.Item
                  text={`${r.time}${r.shift !== 0 ? `, ${r.date}` : ""}`}
                />
              </Detail.Metadata.TagList>
            ))}
          </Detail.Metadata>
        }
      />
    );
  }

  // list view — every zone with its full row of detail
  return (
    <List
      navigationTitle={isCustom ? `Ref: ${at.toLocaleString()}` : "Timezones"}
      actions={pinActions()}
    >
      {rows.length === 0 && (
        <List.EmptyView
          title="No timezones pinned"
          description="⌘P to pin one"
        />
      )}
      {rows.map((r) => (
        <List.Item
          key={r.tz}
          icon={{
            source:
              r.shift === 0
                ? Icon.Circle
                : r.shift === 1
                  ? Icon.ArrowUp
                  : Icon.ArrowDown,
            tintColor:
              r.shift === 0 ? "#99947F" : r.shift === 1 ? "#CA8A04" : "#3D82F2",
          }}
          title={zoneTitle(r.tz)}
          subtitle={r.offset}
          accessories={[
            { tag: { value: r.rel, color: "#99947F" } },
            { tag: r.time },
            { text: r.shift !== 0 ? r.date : "" },
          ]}
          actions={
            <ActionPanel>
              <Action.CopyToClipboard
                title="Copy Time"
                content={`${r.time} ${r.offset} — ${zoneTitle(r.tz)}${r.shift !== 0 ? `, ${r.date}` : ""}`}
                shortcut={{ modifiers: ["cmd"], key: "c" }}
              />
              <Action
                title="Unpin"
                icon={Icon.Minus}
                onAction={() => toggle(r.tz)}
              />
              {pinActions()}
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}
