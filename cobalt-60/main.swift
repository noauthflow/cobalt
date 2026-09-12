import AppKit
import CoreGraphics

// cobalt-60 — keeps the mouse cursor from entering the top 5px of the
// screen (the menu bar area). event-tap based, zero polling. runs as a
// launchd agent; install/uninstall lives in install.sh.

let TOP_MARGIN: CGFloat = 5

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
