import Foundation
import CoreGraphics

// cerulean — completely enable/disable a display on macOS (27.x tested)
// Uses private SkyLight APIs (same family BetterDisplay uses).
//
// Reverse-engineered signatures on macOS 27 (arg order is NOT the old CGS order!):
//   SLSMainConnectionID() -> cid
//   SLSBeginDisplayConfiguration(&config, cid)                    // config FIRST
//   SLSConfigureDisplayEnabled(config, display, enabled, cid)     // enabled BEFORE cid
//   SLSCompleteDisplayConfiguration(config, cid, option)          // option 3 works
//   SLSCancelDisplayConfiguration(config, cid)                    // config FIRST
//
// usage: cerulean [list|off|on|on-all|watch]
//   watch  = daemon: keeps every external display disabled while the state
//            file exists. Re-applies on replug / sleep-wake / login (launchd).

typealias CGSConnectionID = UInt32
typealias CGSDisplayConfigRef = UnsafeMutableRawPointer?

let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!

func sym<T>(_ name: String, _ type: T.Type) -> T {
    guard let p = dlsym(sl, name) else { fatalError("symbol \(name) not found on this macOS") }
    return unsafeBitCast(p, to: type)
}

let mainConn = sym("SLSMainConnectionID", (@convention(c) () -> CGSConnectionID).self)
typealias BeginFn = @convention(c) (UnsafeMutablePointer<CGSDisplayConfigRef>, CGSConnectionID) -> CGError
typealias SetEnabledFn = @convention(c) (CGSDisplayConfigRef, CGDirectDisplayID, UInt32, CGSConnectionID) -> CGError
typealias CompleteFn = @convention(c) (CGSDisplayConfigRef, CGSConnectionID, UInt32) -> CGError
typealias CancelFn = @convention(c) (CGSDisplayConfigRef, CGSConnectionID) -> CGError
typealias OnlineListFn = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>?) -> CGError

let beginCfg = sym("SLSBeginDisplayConfiguration", BeginFn.self)
let setEnabled = sym("SLSConfigureDisplayEnabled", SetEnabledFn.self)
let completeCfg = sym("SLSCompleteDisplayConfiguration", CompleteFn.self)
let cancelCfg = sym("SLSCancelDisplayConfiguration", CancelFn.self)
let onlineList = sym("SLSGetOnlineDisplayList", OnlineListFn.self)

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    _ = onlineList(16, &ids, &count)
    return Array(ids[0..<Int(count)])
}

func apply(_ display: CGDirectDisplayID, _ enable: Bool) {
    let cid = mainConn()
    var config: CGSDisplayConfigRef = nil
    let e1 = beginCfg(&config, cid)
    guard e1 == .success else { print("begin failed: \(e1.rawValue)"); exit(1) }
    let e2 = setEnabled(config, display, enable ? 1 : 0, cid)
    guard e2 == .success else {
        print("setEnabled failed: \(e2.rawValue)")
        _ = cancelCfg(config, cid)
        exit(1)
    }
    let e3 = completeCfg(config, cid, 3)
    guard e3 == .success else {
        print("complete failed: \(e3.rawValue)")
        _ = cancelCfg(config, cid)
        exit(1)
    }
}

func onlineDisplaysCG() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(32, &ids, &count)
    return Array(ids[0..<Int(count)])
}

func label(_ d: CGDirectDisplayID) -> String {
    String(format: "0x%08x (vendor 0x%08x)", d, CGDisplayVendorNumber(d))
}

let stateFile = NSString(string: "~/.cerulean_disabled").expandingTildeInPath

func saveDisabled(_ ids: [CGDirectDisplayID]) {
    try? ids.map { String(format: "0x%08x", $0) }.joined(separator: "\n")
        .write(toFile: stateFile, atomically: true, encoding: .utf8)
}

func loadDisabled() -> [CGDirectDisplayID] {
    guard let s = try? String(contentsOfFile: stateFile, encoding: .utf8) else { return [] }
    return s.split(separator: "\n").compactMap { UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: cerulean [list|off|on|on-all|watch]")
    exit(1)
}

let main = CGMainDisplayID()

// Re-apply 'off': if the state file exists, disable every non-main display
// that is currently online (SLS + public CG lists, to be safe), and refresh
// the saved IDs so 'on' can find them even if IDs changed on replug.
func enforceOff() {
    guard FileManager.default.fileExists(atPath: stateFile) else { return }
    let nowMain = CGMainDisplayID()
    let targets = Set(onlineDisplays()).union(onlineDisplaysCG()).filter { $0 != nowMain }
    guard !targets.isEmpty else { return }
    for d in targets {
        apply(d, false)
        print("[watch] disabled \(label(d))")
    }
    saveDisabled(Array(targets))
}

// C-function-pointer entry for CGDisplayRegisterReconfigurationCallback
func reconfCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    enforceOff()
}

switch args[1] {
case "list":
    print("main:     \(label(main))")
    for d in onlineDisplays().filter({ $0 != main }) { print("external: \(label(d))") }

case "off":
    let targets = onlineDisplays().filter { $0 != main }
    for d in targets {
        apply(d, false)
        print("disabled \(label(d))")
    }
    saveDisabled(targets)
    print("state saved — if the watch agent is running, replug/sleep/reboot will not bring it back")

case "on":
    // remove the intent flag FIRST so a running watcher doesn't re-disable
    let saved = loadDisabled()
    try? FileManager.default.removeItem(atPath: stateFile)
    let targets = Set(saved).union(onlineDisplays()).union(onlineDisplaysCG()).filter { $0 != main }
    if targets.isEmpty { print("no recorded disabled displays (\(stateFile) empty)"); exit(1) }
    for d in targets {
        apply(d, true)
        print("enabled \(label(d))")
    }

case "on-all":
    try? FileManager.default.removeItem(atPath: stateFile)
    let all = Set(onlineDisplays()).union(onlineDisplaysCG()).union(loadDisabled())
    for d in all {
        apply(d, true)
        print("enabled \(label(d))")
    }

case "watch":
    enforceOff()  // catch anything that appeared before we started
    CGDisplayRegisterReconfigurationCallback(reconfCallback, nil)
    Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in enforceOff() }
    print("[watch] enforcing 'off' (state file: \(stateFile))")
    RunLoop.main.run()  // never returns

default:
    print("unknown command: \(args[1])")
    exit(1)
}
