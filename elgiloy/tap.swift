import AppKit
import ApplicationServices

// the only interception point. the tap is active but deliberately passes
// through EVERYTHING except esc-while-overlay-is-open and the bracket tab
// cycle (cmd+shift+[/], swallowed so chrome never cycles on its own). chrome
// performs every tab switch itself; we just watch.
enum Tap {
    static var tap: CFMachPort?

    static func install() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, _ in
            let ctrl = event.flags.contains(.maskControl)
            let cmd = event.flags.contains(.maskCommand)
            let opt = event.flags.contains(.maskAlternate)
            switch type {
            case .flagsChanged:
                if !ctrl && !cmd && !opt {
                    // ctrl, cmd AND option all released → session over →
                    // hide. nothing to commit: every advance already
                    // switched chrome in real time. (any of the three can
                    // carry a session, so only when NONE are down is it
                    // over.)
                    App.shared.end()
                } else if event.flags.contains(.maskShift), ctrl || opt, !App.shared.open {
                    // ctrl+shift or option+shift held together, overlay not
                    // open, modifier still down → just SHOW the overlay. no
                    // cycling, no key press needed — the modifier combo
                    // itself is the trigger. (a tab / bracket tapped
                    // afterwards does the cycling.)
                    let front = NSWorkspace.shared.frontmostApplication
                    if front.map({ Browser.isChromiumFamily($0) }) == true {
                        App.shared.begin()
                    }
                }
                return Unmanaged.passUnretained(event)

            case .keyDown:
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if code == 48, ctrl || opt {        // tab — ours only while we own the cycle
                    let front = NSWorkspace.shared.frontmostApplication
                    let chromium = front.map { Browser.isChromiumFamily($0) } ?? false
                    if App.shared.open || chromium {
                        let shift = event.flags.contains(.maskShift)
                        if App.shared.open {
                            App.shared.advance(shift: shift)
                        } else {
                            // first ctrl+tab: open AND cycle — the first
                            // press is a real switch, not just "show me the
                            // list". (ctrl+shift is the no-cycle way in.)
                            App.shared.begin()
                            App.shared.advance(shift: shift)
                        }
                        return nil
                    }
                    // frontmost isn't chromium and no overlay open: not ours.
                    // pass it through so other apps keep ctrl+tab working.
                    return Unmanaged.passUnretained(event)
                }
                if code == 33 || code == 30, cmd {   // [ / ] — chrome's native
                    // cmd+shift+bracket tab cycling, mirrored like ctrl+tab.
                    // swallowed in chromium apps so chrome never cycles on its
                    // own; [ goes left/previous, ] goes right/next.
                    let front = NSWorkspace.shared.frontmostApplication
                    let chromium = front.map { Browser.isChromiumFamily($0) } ?? false
                    if App.shared.open || (chromium && event.flags.contains(.maskShift)) {
                        let back = code == 33
                        if App.shared.open {
                            App.shared.advance(shift: back)
                        } else {
                            // first bracket press: open AND cycle — the first
                            // press is a real switch, not just "show me the
                            // list". (cmd+shift alone is the no-cycle way in.)
                            App.shared.begin()
                            App.shared.advance(shift: back)
                        }
                        return nil
                    }
                    // frontmost isn't chromium and no overlay open: not ours.
                    // pass it through so other apps keep cmd+shift+[/] working.
                    return Unmanaged.passUnretained(event)
                }
                if code == 13, App.shared.open {   // w — close the selected tab
                    App.shared.closeSelected()
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
            fputs("elgiloy: tap create failed (accessibility not granted?)\n", stderr)
            return
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        // macOS silently disables a tap when its callback times out. a dead
        // tap means missed ctrl-release events → the overlay freezes on
        // screen with no way to dismiss it. revive on a timer; enabling an
        // already-enabled tap is a harmless no-op.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        }

        fputs("elgiloy: tap attached\n", stderr)
    }

    // accessibility grants are tied to the binary's signature — poll until
    // granted instead of dying, so the toggle dance self-heals
    static func watchAndInstall() {
        if AXIsProcessTrusted() { install(); return }
        fputs("elgiloy: waiting for accessibility grant…\n", stderr)
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                install()
            }
        }
    }
}
