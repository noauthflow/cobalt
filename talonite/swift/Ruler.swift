// talonite ruler — native helper.
//
// covers the screen under the cursor with a transparent crosshair overlay,
// measures two points (click A then click B, or one drag in dragMode),
// and prints the straight-line distance as a JSON string on stdout.
// distances are in screen points (the coordinates NSEvent reports and the
// units CSS/layout use); labelled px to match the oracle.
//
// esc or right-click cancels (prints null), space accepts the point under
// the crosshair. holding cmd snaps the measured line to 45° increments
// around the start point. no args beyond dragMode, no permissions — the
// overlay is our own key window.

import AppKit

private final class RulerWindow: NSWindow {
  override var canBecomeKey: Bool { true }
}

private final class RulerView: NSView {
  let dragMode: Bool
  var start: NSPoint?
  var current = NSPoint(x: -1, y: -1)
  var onFinish: ((String?) -> Void)?
  private var finished = false
  private var snapping = false

  init(frame: NSRect, dragMode: Bool) {
    self.dragMode = dragMode
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("unsupported") }

  func handle(_ event: NSEvent) {
    switch event.type {
    case .mouseMoved, .leftMouseDragged:
      current = convert(event.locationInWindow, from: nil)
      needsDisplay = true

    case .flagsChanged:
      snapping = event.modifierFlags.contains(.command)
      needsDisplay = true

    case .leftMouseDown:
      let p = convert(event.locationInWindow, from: nil)
      current = p
      if start == nil {
        start = p
        needsDisplay = true
      } else if !dragMode, let s = start {
        finish(Self.distanceLabel(from: s, to: effectiveEnd()))
      }

    case .leftMouseUp:
      if dragMode, let s = start {
        finish(Self.distanceLabel(from: s, to: effectiveEnd()))
      }

    case .keyDown:
      if event.keyCode == 53 { // esc — cancel
        finish(nil)
      } else if event.keyCode == 49, let s = start, !dragMode { // space — accept current point
        finish(Self.distanceLabel(from: s, to: effectiveEnd()))
      }

    case .rightMouseDown, .otherMouseDown:
      finish(nil)

    default:
      break
    }
  }

  // the endpoint the line and the measurement use: with cmd held, the line
  // from the start point snaps to the nearest multiple of 45° and the end
  // point is the cursor projected onto that ray — so the measured length is
  // the length of the line you actually see (e.g. a horizontal snap reads
  // |dx|), not the diagonal distance to the raw cursor
  private func effectiveEnd() -> NSPoint {
    guard let s = start, snapping else { return current }
    let dx = current.x - s.x
    let dy = current.y - s.y
    guard hypot(dx, dy) > 0 else { return current }
    let step = Double.pi / 4
    let angle = (atan2(dy, dx) / step).rounded() * step
    let t = dx * cos(angle) + dy * sin(angle)
    return NSPoint(x: s.x + CGFloat(t * cos(angle)), y: s.y + CGFloat(t * sin(angle)))
  }

  static func distanceLabel(from a: NSPoint, to b: NSPoint) -> String {
    let d = hypot(b.x - a.x, b.y - a.y)
    return d == d.rounded() ? String(format: "%.0f", d) : String(format: "%.1f", d)
  }

  func finish(_ result: String?) {
    guard !finished else { return }
    finished = true
    onFinish?(result)
  }

  // ------------------------------------------------------------ drawing

  override func draw(_ dirtyRect: NSRect) {
    if current.x >= 0 { drawCrosshair(at: current) }

    if let s = start {
      let end = effectiveEnd()
      // the measured line — amber while cmd-snapped to 45°, white otherwise
      let line = NSBezierPath()
      line.lineWidth = 1.5
      line.move(to: s)
      line.line(to: end)
      (snapping ? NSColor(red: 0.79, green: 0.54, blue: 0.02, alpha: 1) : NSColor.white.withAlphaComponent(0.9)).setStroke()
      line.stroke()

      for p in [s, end] {
        let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        NSColor.white.setStroke()
        dot.lineWidth = 1.5
        dot.stroke()
      }

      drawChip(Self.distanceLabel(from: s, to: end), at: midpoint(s, end))
    }

    drawChip("\(Int(current.x)) × \(Int(current.y))", at: current)
  }

  private func midpoint(_ a: NSPoint, _ b: NSPoint) -> NSPoint {
    NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
  }

  private func drawCrosshair(at p: NSPoint) {
    let cross = NSBezierPath()
    cross.lineWidth = 0.5
    NSColor.white.withAlphaComponent(0.35).setStroke()
    cross.move(to: NSPoint(x: 0, y: p.y))
    cross.line(to: NSPoint(x: bounds.maxX, y: p.y))
    cross.move(to: NSPoint(x: p.x, y: 0))
    cross.line(to: NSPoint(x: p.x, y: bounds.height))
    cross.stroke()
  }

  private func drawChip(_ text: String, at point: NSPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let size = (text as NSString).size(withAttributes: attrs)
    let pad: CGFloat = 5
    let margin: CGFloat = 12

    var origin = NSPoint(x: point.x + margin, y: point.y + margin)
    if origin.x + size.width + pad * 2 > bounds.maxX { origin.x = point.x - margin - size.width - pad * 2 }
    if origin.y + size.height + pad * 2 > bounds.maxY { origin.y = point.y - margin - size.height - pad * 2 }

    let chip = NSRect(x: origin.x, y: origin.y, width: size.width + pad * 2, height: size.height + pad * 2)
    NSColor.black.withAlphaComponent(0.78).setFill()
    NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
    (text as NSString).draw(
      at: NSPoint(x: chip.minX + pad, y: chip.minY + pad),
      withAttributes: attrs
    )
  }
}

func measureDistance(dragMode: Bool) -> String? {
  let mouse = NSEvent.mouseLocation
  let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
  guard let screen else { return nil }

  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  app.activate(ignoringOtherApps: true)

  let window = RulerWindow(
    contentRect: screen.frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
  )
  window.level = .screenSaver
  window.isOpaque = false
  window.backgroundColor = .clear
  window.hasShadow = false
  window.ignoresMouseEvents = false
  window.acceptsMouseMovedEvents = true

  let view = RulerView(frame: NSRect(origin: .zero, size: screen.frame.size), dragMode: dragMode)
  window.contentView = view
  window.makeKeyAndOrderFront(nil)
  window.makeFirstResponder(view)
  NSCursor.crosshair.push()

  var result: String?
  var running = true
  view.onFinish = { r in
    result = r
    running = false
  }

  while running {
    if let event = app.nextEvent(matching: .any, until: .distantFuture, inMode: .default, dequeue: true) {
      view.handle(event)
    }
  }

  NSCursor.pop()
  window.orderOut(nil)
  return result
}

// ------------------------------------------------------------ dispatch

func json(_ value: String?) -> String {
  guard let value else { return "null" }
  let encoded = try? JSONEncoder().encode(value)
  return String(data: encoded ?? Data("null".utf8), encoding: .utf8) ?? "null"
}

let args = CommandLine.arguments
guard args.count > 1 else {
  FileHandle.standardError.write("a swift function name is required\n".data(using: .utf8)!)
  exit(1)
}
switch args[1] {
case "measureDistance":
  var dragMode = false
  if args.count > 2 {
    dragMode = (try? JSONDecoder().decode(Bool.self, from: Data(args[2].utf8))) ?? false
  }
  print(json(measureDistance(dragMode: dragMode)))
default:
  FileHandle.standardError.write("unknown function: \(args[1])\n".data(using: .utf8)!)
  exit(1)
}