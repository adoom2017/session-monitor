// Draws the SessionMonitor app icon with CoreGraphics (no external tools).
// Usage: swift scripts/make-icon.swift <output-dir>   → <output-dir>/AppIcon.icns (+ preview.png)
// The icon is the app in miniature: a floating session panel whose rows carry the app's state
// colors (orange = needs you, blue ✓ = done, green … = working) on a deep-blue macOS squircle.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon() {
  // macOS icon grid: 824pt rounded-square body centered on the 1024 canvas.
  let body = NSRect(x: 100, y: 100, width: 824, height: 824)
  let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

  NSGraphicsContext.saveGraphicsState()
  let drop = NSShadow()
  drop.shadowColor = color(0x000000, 0.35)
  drop.shadowOffset = NSSize(width: 0, height: -14)
  drop.shadowBlurRadius = 28
  drop.set()
  color(0x2B3290).setFill()
  bodyPath.fill()
  NSGraphicsContext.restoreGraphicsState()

  NSGradient(colors: [color(0x5A6CF0), color(0x2B3290)])!.draw(in: bodyPath, angle: -90)
  // Soft top sheen.
  NSGraphicsContext.saveGraphicsState()
  bodyPath.addClip()
  NSGradient(colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)])!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
  NSGraphicsContext.restoreGraphicsState()

  // Floating panel.
  let panel = NSRect(x: 222, y: 238, width: 580, height: 548)
  let panelPath = NSBezierPath(roundedRect: panel, xRadius: 64, yRadius: 64)
  NSGraphicsContext.saveGraphicsState()
  let lift = NSShadow()
  lift.shadowColor = color(0x0B0F3A, 0.45)
  lift.shadowOffset = NSSize(width: 0, height: -18)
  lift.shadowBlurRadius = 40
  lift.set()
  color(0xFBF7EC).setFill()
  panelPath.fill()
  NSGraphicsContext.restoreGraphicsState()

  // Rows, top to bottom: needs you, done, working.
  let rows: [(dot: UInt32, bar: CGFloat, mark: String)] = [
    (0xFF9F0A, 300, "!"), (0x0A84FF, 240, "✓"), (0x30C759, 270, "…"),
  ]
  let rowHeight: CGFloat = 164
  for (index, row) in rows.enumerated() {
    let centerY = panel.maxY - 110 - CGFloat(index) * rowHeight
    let dot = NSRect(x: panel.minX + 62, y: centerY - 48, width: 96, height: 96)
    color(row.dot).setFill()
    NSBezierPath(ovalIn: dot).fill()
    if row.mark == "…" {
      // Working: the ellipsis used for this state in the panel.
      NSColor.white.setFill()
      for offset: CGFloat in [-26, 0, 26] {
        NSBezierPath(ovalIn: NSRect(x: dot.midX + offset - 9, y: dot.midY - 9, width: 18, height: 18))
          .fill()
      }
    } else if !row.mark.isEmpty {
      let font = NSFont.systemFont(ofSize: 66, weight: .heavy)
      let text = NSAttributedString(
        string: row.mark, attributes: [.font: font, .foregroundColor: NSColor.white])
      let size = text.size()
      text.draw(at: NSPoint(x: dot.midX - size.width / 2, y: dot.midY - size.height / 2 + 2))
    }
    // Title bar (darker) and a shorter detail bar, like a session row.
    color(0x3A3F5C, 0.85).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: dot.maxX + 40, y: centerY + 4, width: row.bar, height: 34),
      xRadius: 17, yRadius: 17
    ).fill()
    color(0x3A3F5C, 0.28).setFill()
    NSBezierPath(
      roundedRect: NSRect(x: dot.maxX + 40, y: centerY - 42, width: row.bar * 0.62, height: 26),
      xRadius: 13, yRadius: 13
    ).fill()
    if index < rows.count - 1 {
      color(0x3A3F5C, 0.10).setFill()
      NSRect(x: panel.minX + 50, y: centerY - rowHeight / 2 - 1, width: panel.width - 100, height: 3)
        .fill()
    }
  }
}

func render(_ pixels: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: canvas, height: canvas)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  drawIcon()
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = output.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
  try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: output.appendingPathComponent("preview.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
  "-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
print("wrote \(output.appendingPathComponent("AppIcon.icns").path)")
