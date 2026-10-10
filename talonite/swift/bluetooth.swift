// talonite bluetooth — native helper.
//
// talks to IOBluetooth directly: enumerates paired devices with their live
// connection state, connects via openConnection() and disconnects via
// closeConnection() — the same calls the Bluetooth system pane makes. the
// first call triggers macOS's Bluetooth permission prompt for Raycast;
// after granting it once, everything runs without further dialogs.
//
// called by src/native.ts as `bluetooth listDevices`,
// `bluetooth connectDevice {"address":"xx-xx-.."}` or
// `bluetooth disconnectDevice {"address":".."}`; prints the result as JSON
// on stdout, null when nothing was produced.

import IOBluetooth

struct BTDevice: Codable {
  var name: String
  // colon-separated MAC, e.g. "B0:BE:83:F3:4C:D4"
  var address: String
  var isConnected: Bool
  var isFavorite: Bool
  // false for paired-but-not-connectable LE gadgets (beacons, app pendants…)
  // — these are what System Settings hides
  var isConnectable: Bool
  // "keyboard" | "mouse" | "unknown"
  var kind: String
}

func devices() -> [IOBluetoothDevice] {
  // pairedDevices() is imported as a retained [Any]
  (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
}

// BLE HID devices leave classOfDevice empty, so their type has to come from
// blued's own scan data — system_profiler reports device_minorType (Keyboard,
// Mouse, …) keyed by address. system_profiler costs 300–500ms per call, so
// the raw report is cached to disk and parsed on read; a detached refresh
// keeps the cache warm without ever blocking a list.
func parseTypes(_ data: Data) -> [String: String] {
  var map: [String: String] = [:]
  func normalize(_ a: String) -> String {
    a.lowercased().replacingOccurrences(of: ":", with: "-")
  }
  if var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let items = root.removeValue(forKey: "SPBluetoothDataType") as? [[String: Any]]
  {
    for item in items {
      for (_, section) in item {
        guard let entries = section as? [[String: Any]] else { continue }
        for entry in entries {
          // entries are either flat or a single-key {displayName: fields} dict
          var fields: [String: Any]? = entry["device_address"] != nil ? entry : nil
          if fields == nil {
            for v in entry.values {
              if let d = v as? [String: Any], d["device_address"] != nil {
                fields = d
                break
              }
            }
          }
          guard let f = fields,
            let addr = f["device_address"] as? String,
            let t = f["device_minorType"] as? String
          else { continue }
          map[normalize(addr)] = t.lowercased()
        }
      }
    }
  }
  return map
}

func typesCachePath() -> String {
  NSTemporaryDirectory() + "talonite_bt_minor_types.json"
}

// cache-only read — instant, never spawns system_profiler
func cachedTypes() -> [String: String] {
  guard let data = FileManager.default.contents(atPath: typesCachePath()) else { return [:] }
  return parseTypes(data)
}

// if the cache is missing or older than the ttl, kick off a detached
// system_profiler that lands in the cache via a tmp-and-mv (the sh survives
// our exit, so the write completes even though we return immediately)
func refreshTypesInBackground() {
  let ttl: TimeInterval = 600
  let path = typesCachePath()
  let fm = FileManager.default
  if let attrs = try? fm.attributesOfItem(atPath: path),
    let mtime = attrs[.modificationDate] as? Date,
    Date().timeIntervalSince(mtime) < ttl
  { return }
  let tmp = path + ".tmp"
  let sh = Process()
  sh.executableURL = URL(fileURLWithPath: "/bin/sh")
  sh.arguments = [
    "-c",
    "/usr/sbin/system_profiler SPBluetoothDataType -json > '\(tmp)' && mv '\(tmp)' '\(path)'",
  ]
  sh.standardError = FileHandle.nullDevice
  try? sh.run() // deliberately not waited on
}

// classic devices carry a full class-of-device; keyboard = major Peripheral
// (5) minor 0x10, mouse = major 5 minor 0x20 (pointing). BLE HID gear reports
// class 0 — fall through to blued's minorType, then give up and show the rune
func classify(_ cls: UInt32, _ minorType: String?) -> String {
  let major = (cls >> 8) & 0x1F
  let minor = (cls >> 2) & 0x3F
  if major == 5 && minor == 0x10 { return "keyboard" }
  if major == 5 && minor == 0x20 { return "mouse" }
  if let t = minorType {
    if t.contains("keyboard") { return "keyboard" }
    if t.contains("mouse") || t.contains("pointing") || t.contains("trackpad") {
      return "mouse"
    }
  }
  return "unknown"
}

func describe(_ device: IOBluetoothDevice, _ types: [String: String], _ haveCache: Bool) -> BTDevice {
  let cls = (device.value(forKey: "classOfDevice") as? NSNumber)?.uint32Value ?? 0
  let minorType = types[device.addressString.lowercased()]
  // "connectable" = the things System Settings shows: has a real device type
  // in blued's report, or is currently connected. Passive BLE gadgets (rssi-
  // only entries) sit in the registry but can't be connected. With no cache
  // at all we can't tell, so err on the side of showing everything.
  let connectable = device.isConnected() || minorType != nil || !haveCache
  return BTDevice(
    name: device.name ?? "Unknown",
    address: device.addressString,
    isConnected: device.isConnected(),
    isFavorite: device.isFavorite(),
    isConnectable: connectable,
    kind: classify(cls, minorType)
  )
}

func listDevices() -> [BTDevice] {
  // kinds come from the disk cache (instant); the report refresh happens
  // detached so a stale cache never blocks the list
  let types = cachedTypes()
  let haveCache = FileManager.default.fileExists(atPath: typesCachePath())
  refreshTypesInBackground()
  return devices()
    .map { describe($0, types, haveCache) }
    .sorted { lhs, rhs in
      if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
      return lhs.name < rhs.name
    }
}

struct AddressRequest: Codable {
  var address: String
}

func find(_ address: String) -> IOBluetoothDevice? {
  devices().first { $0.addressString == address }
}

// openConnection() kicks the attempt off and returns immediately; the
// handshake continues in the background, so the caller re-lists after a beat
func connect(_ req: AddressRequest) -> Bool {
  guard let device = find(req.address) else { return false }
  if device.isConnected() { return true }
  return device.openConnection() == kIOReturnSuccess
}

func disconnect(_ req: AddressRequest) -> Bool {
  guard let device = find(req.address) else { return false }
  if !device.isConnected() { return true }
  return device.closeConnection() == kIOReturnSuccess
}

// flips whichever way the device sits *at call time* — safer than deciding
// from a possibly stale list on the TS side
func toggle(_ req: AddressRequest) -> Bool {
  guard let device = find(req.address) else { return false }
  return device.isConnected() ? device.closeConnection() == kIOReturnSuccess : device.openConnection() == kIOReturnSuccess
}

// ------------------------------------------------------------ dispatch

func json<T: Encodable>(_ value: T) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return String(data: (try? encoder.encode(value)) ?? Data("null".utf8), encoding: .utf8) ?? "null"
}

func decodeRequest(_ raw: String?) -> AddressRequest? {
  guard let raw, let data = raw.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(AddressRequest.self, from: data)
}

let args = CommandLine.arguments
guard args.count > 1 else {
  FileHandle.standardError.write("a swift function name is required\n".data(using: .utf8)!)
  exit(1)
}
switch args[1] {
case "listDevices":
  print(json(listDevices()))
case "connectDevice", "disconnectDevice", "toggleDevice":
  guard let req = decodeRequest(args.count > 2 ? args[2] : nil) else {
    FileHandle.standardError.write("an {address} argument is required\n".data(using: .utf8)!)
    exit(1)
  }
  let ok: Bool
  switch args[1] {
  case "connectDevice": ok = connect(req)
  case "disconnectDevice": ok = disconnect(req)
  default: ok = toggle(req)
  }
  print(json(ok))
default:
  FileHandle.standardError.write("unknown function: \(args[1])\n".data(using: .utf8)!)
  exit(1)
}
