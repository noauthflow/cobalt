import AppKit
import CoreGraphics

// cobalt-60 — keeps the mouse cursor from entering the top N px of the
// screen (the menu bar area). event-tap based, zero polling.
//
//   cobalt-60              daemon mode (what launchd runs)
//   cobalt-60 install      build + sign + register launchd agent + start
//   cobalt-60 uninstall    stop agent + remove plist
//   cobalt-60 start        start the agent (kickstart)
//   cobalt-60 stop         stop the agent (plist stays for next login)
//   cobalt-60 status       installed / running / pid

let TOP_MARGIN: CGFloat = 5
let label = "dev.cobalt.cobalt-60"
let home = FileManager.default.homeDirectoryForCurrentUser.path
let plistPath = "\(home)/Library/LaunchAgents/\(label).plist"

// MARK: - helpers

func sh(_ command: String) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}

func guiID() -> String { String(getuid()) }

func agentRunning() -> Bool {
    sh("pgrep -x cobalt-60 >/dev/null 2>&1").status == 0
}

func agentLoaded() -> Bool {
    sh("launchctl print gui/\(guiID())/\(label) >/dev/null 2>&1").status == 0
}

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

// MARK: - subcommands

func install() {
    let bin = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let dir = (bin as NSString).deletingLastPathComponent

    print("building (swiftc)")
    let (buildStatus, buildErr) = sh("cd '\(dir)' && swiftc -O -o '\(bin)' main.swift -framework AppKit 2>&1")
    if buildStatus != 0 {
        print("build failed:\n\(buildErr)"); exit(1)
    }

    // sign with the persistent self-signed cert if it exists — keeps the
    // accessibility grant valid across rebuilds (ad-hoc binaries invalidate it)
    let (_, identities) = sh("security find-identity -v -p codesigning")
    if identities.contains("cobalt-dev") {
        _ = sh("codesign --force --sign cobalt-dev '\(bin)' 2>/dev/null")
        print("signed (cobalt-dev) — accessibility grant survives rebuilds")
    } else {
        print("note: no 'cobalt-dev' codesigning cert; rebuilds will need a re-grant")
    }

    launchctlStop()
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>\(label)</string>
      <key>ProgramArguments</key><array><string>\(bin)</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardErrorPath</key><string>/tmp/cobalt-60.err</string>
    </dict></plist>
    """
    try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    let (bootStatus, bootErr) = sh("launchctl bootstrap gui/\(guiID()) '\(plistPath)'")
    if bootStatus != 0 && !agentLoaded() {
        print("launchd bootstrap failed: \(bootErr)"); exit(1)
    }

    print("installed: \(bin)")
    print("launchd:   \(label) — starts at login, restarts on crash")
    if sh("pgrep -x cobalt-60 >/dev/null").status != 0 {
        print()
        print("one-time setup:")
        print("  system settings -> privacy & security -> accessibility")
        print("  add: \(bin)")
        print("  logs: tail -f /tmp/cobalt-60.err")
    }
}

func launchctlStop() {
    _ = sh("launchctl bootout gui/\(guiID())/\(label) 2>/dev/null")
    // in case it was started manually outside launchd
    _ = sh("pkill -x cobalt-60 2>/dev/null")
}

func uninstall() {
    launchctlStop()
    try? FileManager.default.removeItem(atPath: plistPath)
    print("uninstalled: agent stopped, plist removed")
    print("(binary and source remain in the repo; accessibility grant may need manual removal)")
}

func start() {
    guard FileManager.default.fileExists(atPath: plistPath) else {
        print("not installed — run: cobalt-60 install"); exit(1)
    }
    if !agentLoaded() {
        _ = sh("launchctl bootstrap gui/\(guiID()) '\(plistPath)'")
    }
    _ = sh("launchctl kickstart -k gui/\(guiID())/\(label)")
    print(agentRunning() ? "started" : "started (may be waiting on accessibility grant — check /tmp/cobalt-60.err)")
}

func stop() {
    launchctlStop()
    print("stopped (plist kept — starts again at next login or `cobalt-60 start`)")
}

func status() {
    let installed = FileManager.default.fileExists(atPath: plistPath)
    print("launchd agent: \(installed ? "installed (\(plistPath))" : "not installed")")
    print("loaded:        \(agentLoaded() ? "yes" : "no")")
    print("process:       \(agentRunning() ? "running" : "not running")")
    print("margin:        \(Int(TOP_MARGIN))px below menu bar")
}

// MARK: - entry

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "run" {
case "run":       runDaemon()
case "install":   install()
case "uninstall": uninstall()
case "start", "enable":  start()
case "stop", "disable":  stop()
case "status":    status()
default:
    print("""
    usage: cobalt-60 [command]

      (none) | run    daemon mode — hold the wall (what launchd runs)
      install         build, sign, register launchd agent, start
      uninstall       stop agent and remove plist
      start, enable   start the agent
      stop, disable   stop the agent (persists across logins)
      status          installed / running / config
    """)
    exit(1)
}
