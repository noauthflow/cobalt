import AppKit
import ApplicationServices

// the only interception point. the tap is active but deliberately passes
// through EVERYTHING except esc-while-overlay-is-open. chrome performs every
// tab switch itself; we just watch.
enum Tap {
    static var tap: CFMachPort?

    static func install() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let ctrl = event.flags.contains(.maskControl)
            switch type {
            case .flagsChanged:
                // ctrl released → cycling over → hide. nothing was changed,
                // so there is nothing to commit.
                if !ctrl { App.shared.end() }
                return Unmanaged.passUnretained(event)

            case .keyDown:
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if code == 48, ctrl {              // tab — swallowed. WE are the cycle.
                    if App.shared.open {
                        App.shared.advance(shift: event.flags.contains(.maskShift))
                    } else {
                        App.shared.begin()
                    }
                    return nil
                }
                if code == 53, App.shared.open {   // esc — the ONE key we swallow
                    App.shared.escPressed()
                    return nil
                }
                return Unmanaged.passUnretained(event)

            default:
                return Unmanaged.passUnretained(event)
            }
        }

        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                           callback: callback, userInfo: nil) else {
            fputs("cobalt-switcher: tap create failed (accessibility not granted?)\n", stderr)
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        fputs("cobalt-switcher: tap attached\n", stderr)
    }

    // accessibility grants are tied to the binary's signature — poll until
    // granted instead of dying, so the toggle dance self-heals
    static func watchAndInstall() {
        if AXIsProcessTrusted() { install(); return }
        fputs("cobalt-switcher: waiting for accessibility grant…\n", stderr)
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                install()
            }
        }
    }
}
