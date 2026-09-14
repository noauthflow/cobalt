// talonite color picker — native helper.
//
// shows the system magnifier loupe (NSColorSampler — the same API the
// oracle's compiled swift binary uses, `showSamplerWithSelectionHandler`)
// and resolves the picked pixel in sRGB.
//
// called by src/native.ts as `color-picker pickColor`; prints the result as
// JSON on stdout (null if the user cancels). no args, no permissions.

import AppKit

struct PickedColor: Codable {
  var colorSpace: String
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double
}

func pickColor() -> PickedColor? {
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  app.activate(ignoringOtherApps: true)

  var result: PickedColor?
  var finished = false

  Task {
    let sampler = NSColorSampler()
    guard let color = await sampler.sample(),
      let srgb = color.usingColorSpace(.sRGB)
    else {
      finished = true
      return
    }
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    result = PickedColor(
      colorSpace: "srgb",
      red: Double(r),
      green: Double(g),
      blue: Double(b),
      alpha: Double(a)
    )
    finished = true
  }

  // the sampler's completion runs on the main thread — keep the runloop
  // alive instead of blocking the thread it needs
  while !finished {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
  }

  return result
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
case "pickColor":
  print(json(pickColor()))
default:
  FileHandle.standardError.write("unknown function: \(args[1])\n".data(using: .utf8)!)
  exit(1)
}