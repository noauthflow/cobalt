// talonite audio switcher — native helper.
//
// talks to CoreAudio directly: enumerates hardware devices, reports which
// side they serve (output/input — a device can serve both), the current
// volume of the output side, and which device is the current default on
// each side. setting a default is the same property write the Sound system
// preference pane performs (kAudioHardwarePropertyDefaultOutputDevice and
// friends on the system object). no permissions, no external tools.
//
// called by src/native.ts as `audio listDevices` or
// `audio setDefaultDevice {"direction":"output","id":85}`; prints the
// result as JSON on stdout, null when nothing was produced.

import CoreAudio

struct AudioDevice: Codable {
  var id: Int
  var uid: String
  var name: String
  var transport: String
  var isOutput: Bool
  var isInput: Bool
  var isDefaultOutput: Bool
  var isDefaultInput: Bool
  // 0-100, output side only; null when the device has no master volume
  var volume: Double?
  var muted: Bool
  // the device system alert sounds use (only ever an output device)
  var isDefaultSystem: Bool
}

func propAddress(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(
    mSelector: selector,
    mScope: scope,
    mElement: kAudioObjectPropertyElementMain
  )
}

func getString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
  var addr = propAddress(selector, scope)
  var value: CFString?
  var size: UInt32 = 0
  guard
    AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
    size > 0
  else { return nil }
  let status = withUnsafeMutablePointer(to: &value) { ptr in
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
  }
  guard status == noErr, let s = value else { return nil }
  return s as String
}

func getUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
  var addr = propAddress(selector, scope)
  var value: UInt32 = 0
  var size = UInt32(MemoryLayout<UInt32>.size)
  let status = withUnsafeMutablePointer(to: &value) { ptr in
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
  }
  return status == noErr ? value : nil
}

func getFloat32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, element: UInt32) -> Float32? {
  var addr = AudioObjectPropertyAddress(
    mSelector: selector, mScope: scope, mElement: element)
  var value: Float32 = 0
  var size = UInt32(MemoryLayout<Float32>.size)
  let status = withUnsafeMutablePointer(to: &value) { ptr in
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
  }
  return status == noErr ? value : nil
}

func getDefaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
  var addr = propAddress(selector)
  var value: AudioObjectID = 0
  var size = UInt32(MemoryLayout<AudioObjectID>.size)
  let status = withUnsafeMutablePointer(to: &value) { ptr in
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
  }
  return status == noErr && value != 0 ? value : nil
}

func setDefaultDevice(_ selector: AudioObjectPropertySelector, id: AudioObjectID) -> Bool {
  var addr = propAddress(selector)
  var value = id
  return AudioObjectSetPropertyData(
    AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
    UInt32(MemoryLayout<AudioObjectID>.size), &value
  ) == noErr
}

// a device serves a side when it has at least one stream on that scope
func serves(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
  var addr = propAddress(kAudioDevicePropertyStreams, scope)
  var size: UInt32 = 0
  guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else {
    return false
  }
  return size > 0
}

func transportName(_ raw: UInt32) -> String {
  switch raw {
  case kAudioDeviceTransportTypeBuiltIn: return "builtin"
  case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
  case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
  case kAudioDeviceTransportTypeAirPlay: return "airplay"
  case kAudioDeviceTransportTypeUSB: return "usb"
  case kAudioDeviceTransportTypeHDMI: return "hdmi"
  case kAudioDeviceTransportTypeDisplayPort: return "displayport"
  case kAudioDeviceTransportTypeFireWire: return "firewire"
  case kAudioDeviceTransportTypePCI: return "pci"
  case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
  case kAudioDeviceTransportTypeVirtual: return "virtual"
  case kAudioDeviceTransportTypeAggregate: return "aggregate"
  default: return "other"
  }
}

// master volume sits on element 0 (elementMain); some hardware only exposes
// it on channel 1, so fall back before giving up
func outputVolume(_ id: AudioObjectID) -> (volume: Double, muted: Bool)? {
  for element in [kAudioObjectPropertyElementMain, 1] {
    if let scalar = getFloat32(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element: element) {
      let muted = getFloat32(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, element: element)
      return (Double(scalar), muted.map { $0 > 0.5 } ?? false)
    }
  }
  return nil
}

func listDevices() -> [AudioDevice] {
  var addr = propAddress(kAudioHardwarePropertyDevices)
  var size: UInt32 = 0
  guard
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
    size > 0
  else { return [] }

  let count = Int(size) / MemoryLayout<AudioDeviceID>.size
  var ids = [AudioDeviceID](repeating: 0, count: count)
  let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
  guard status == noErr else { return [] }

  let defaultOut = getDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
  let defaultIn = getDefaultDevice(kAudioHardwarePropertyDefaultInputDevice)
  let defaultSystem = getDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)

  var devices: [AudioDevice] = []
  for id in ids where id != 0 {
    let isOutput = serves(id, kAudioObjectPropertyScopeOutput)
    let isInput = serves(id, kAudioObjectPropertyScopeInput)
    guard isOutput || isInput else { continue }
    let vol = isOutput ? outputVolume(id) : nil
    devices.append(
      AudioDevice(
        id: Int(id),
        uid: getString(id, kAudioDevicePropertyDeviceUID) ?? "",
        name: getString(id, kAudioObjectPropertyName) ?? "Unknown",
        transport: getUInt32(id, kAudioDevicePropertyTransportType)
          .map(transportName) ?? "other",
        isOutput: isOutput,
        isInput: isInput,
        isDefaultOutput: id == defaultOut,
        isDefaultInput: id == defaultIn,
        volume: vol.map { round($0.volume * 100) },
        muted: vol?.muted ?? false,
        isDefaultSystem: id == defaultSystem
      )
    )
  }
  return devices.sorted { $0.name < $1.name }
}

struct DefaultRequest: Codable {
  // "output" | "input" | "system"
  var direction: String
  var id: Int
}

func setDefaultDirection(_ req: DefaultRequest) -> Bool {
  let selector: AudioObjectPropertySelector
  switch req.direction {
  case "input": selector = kAudioHardwarePropertyDefaultInputDevice
  case "system": selector = kAudioHardwarePropertyDefaultSystemOutputDevice
  default: selector = kAudioHardwarePropertyDefaultOutputDevice
  }
  return setDefaultDevice(selector, id: AudioObjectID(req.id))
}

// ------------------------------------------------------------ dispatch

func json<T: Encodable>(_ value: T) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return String(data: (try? encoder.encode(value)) ?? Data("null".utf8), encoding: .utf8) ?? "null"
}

let args = CommandLine.arguments
guard args.count > 1 else {
  FileHandle.standardError.write("a swift function name is required\n".data(using: .utf8)!)
  exit(1)
}
switch args[1] {
case "listDevices":
  print(json(listDevices()))
case "setDefaultDevice":
  guard args.count > 2, let data = args[2].data(using: .utf8),
    let req = try? JSONDecoder().decode(DefaultRequest.self, from: data)
  else {
    FileHandle.standardError.write("a {direction, id} argument is required\n".data(using: .utf8)!)
    exit(1)
  }
  print(json(setDefaultDirection(req)))
default:
  FileHandle.standardError.write("unknown function: \(args[1])\n".data(using: .utf8)!)
  exit(1)
}
