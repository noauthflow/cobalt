import AppKit
import CoreGraphics

// cobalt-60 — keeps the mouse cursor from entering the top 5px of the
// screen (the menu bar area). event-tap based, zero polling. runs as a
// launchd agent; install/uninstall lives in install.sh.
//
//   cobalt-60          daemon mode (what launchd runs)
//   cobalt-60 on       start the wall (bootstrap + kickstart the agent)
//   cobalt-60 off      stop the wall (agent unloaded; restarts at next login)
//   cobalt-60 status   installed / loaded / running

let TOP_MARGIN: CGFloat = 5
let label = "dev.cobalt.cobalt-60"
let name = "cobalt-60"
let errLog = "/tmp/cobalt-60.err"
let plistPath = FileManager.default.homeDirectoryForCurrentUser.path
    + "/Library/LaunchAgents/\(label).plist"

// MARK: - tap state (file scope — CGEventTapCallBack is a C function pointer
// and cannot capture local context)

var minYFromTop: CGFloat = 0

func recomputeMinY() {
    guard let mainScreen = NSScreen.screens.first(where: { $0.frame.origin.y == 0 }) ?? NSScreen.main else { return }
    let screenHeight = mainScreen.frame.height
    // bottom edge of the menu bar, as distance from the top of the screen
    minYFromTop = screenHeight - mainScreen.visibleFrame.maxY + TOP_MARGIN
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .mouseMoved, .leftMouseDragged, .otherMouseDragged:
        let loc = event.location
        if loc.y < minYFromTop {
            event.location = CGPoint(x: loc.x, y: minYFromTop)
        }
    default:
        break
    }
    return Unmanaged.passRetained(event)
}

// MARK: - daemon

func runDaemon() -> Never {
    recomputeMinY()
    // recompute on display changes (resolution switch, monitor plug/unplug)
    NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil, queue: nil
    ) { _ in recomputeMinY() }

    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask((1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)),
        callback: tapCallback,
        userInfo: nil
    ) else {
        FileHandle.standardError.write("failed to create event tap — grant accessibility to the binary\n".data(using: .utf8)!)
        exit(1)
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    CFRunLoopRun()
    exit(0)
}

// MARK: - subcommands (thin launchctl wrappers — install/uninstall lives in install.sh)

@discardableResult
func sh(_ command: String) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do { try p.run() } catch { return 1 }
    p.waitUntilExit()
    return p.terminationStatus
}

let gui = "gui/\(getuid())"

func agentLoaded() -> Bool {
    sh("launchctl print \(gui)/\(label) >/dev/null 2>&1") == 0
}

// the daemon registers as "cobalt-60" — but so does this CLI invocation,
// so exclude our own pid from the check
func daemonRunning() -> Bool {
    sh("pgrep -x \(name) | grep -vw \(getpid()) >/dev/null 2>&1") == 0
}

func cmdOn() {
    guard FileManager.default.fileExists(atPath: plistPath) else {
        print("not installed — run install.sh first"); exit(1)
    }
    if !agentLoaded() {
        sh("launchctl bootstrap \(gui) '\(plistPath)'")
    }
    sh("launchctl kickstart -k \(gui)/\(label)")
    print(daemonRunning()
        ? "wall is up — \(Int(TOP_MARGIN))px below the menu bar"
        : "starting… if it won't stay up, check \(errLog) (usually a missing accessibility grant)")
}

func cmdOff() {
    guard agentLoaded() || daemonRunning() else {
        print("already off"); exit(0)
    }
    sh("launchctl bootout \(gui)/\(label)")
    sh("pkill -x \(name) 2>/dev/null")
    print("wall is down (starts again at next login — plist kept)")
}

func cmdStatus() {
    let installed = FileManager.default.fileExists(atPath: plistPath)
    let loaded = agentLoaded()
    let running = daemonRunning()

    print("agent:    \(installed ? "installed (\(plistPath))" : "not installed — run install.sh")")
    print("launchd:  \(loaded ? "loaded" : "not loaded")")
    print("process:  \(running ? "running" : "not running")")

    if running {
        print("wall:     up — cursor held \(Int(TOP_MARGIN))px below the menu bar")
    } else if loaded {
        print("wall:     down — launchd is retrying; check \(errLog)")
        if let tail = try? String(contentsOfFile: errLog, encoding: .utf8).suffix(200) {
            print("log:      \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    } else {
        print("wall:     off (starts again at next login)")
    }
}

// MARK: - entry

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run" {
case "run":              runDaemon()
case "on", "enable":     cmdOn()
case "off", "disable":   cmdOff()
case "status":           cmdStatus()
default:
    print("""
    usage: cobalt-60 [command]

      (none)          daemon mode — hold the wall (what launchd runs)
      on, enable      start the wall
      off, disable    stop the wall (starts again at next login)
      status          installed / loaded / running

    install & uninstall: ./install.sh in the repo folder
    """)
    exit(1)
}
