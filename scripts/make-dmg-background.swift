// Draws the DMG window background with CoreGraphics (no external tools).
// Usage: swift scripts/make-dmg-background.swift <output.png> [scale]
// The layout matches package-release.sh: a 640×400 window, the app icon centered at (170, 190)
// and the Applications link at (470, 190), with an arrow between them and a one-line hint below.
import AppKit

let size = NSSize(width: 640, height: 400)
let appCenter = NSPoint(x: 170, y: 190)
let applicationsCenter = NSPoint(x: 470, y: 190)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw() {
  let bounds = NSRect(origin: .zero, size: size)
  // Frosted white canvas with the app's faint blue/purple ambient light (docs/DESIGN.md).
  NSGradient(colors: [color(0xFFFFFF), color(0xEEF2F8)])!.draw(in: bounds, angle: 90)
  NSGradient(colors: [color(0x0066CC, 0.10), color(0x8944AB, 0.05), color(0x8944AB, 0)])!
    .draw(fromCenter: NSPoint(x: 0, y: 0), radius: 0, toCenter: NSPoint(x: 0, y: 0), radius: 420,
      options: [])

  // Arrow from the app to Applications, clear of the 128pt icons.
  let y = appCenter.y
  let start = appCenter.x + 88, end = applicationsCenter.x - 88
  let arrow = NSBezierPath()
  arrow.lineWidth = 5
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  arrow.move(to: NSPoint(x: start, y: y))
  arrow.line(to: NSPoint(x: end, y: y))
  arrow.move(to: NSPoint(x: end - 16, y: y - 16))
  arrow.line(to: NSPoint(x: end, y: y))
  arrow.line(to: NSPoint(x: end - 16, y: y + 16))
  color(0x0066CC, 0.55).setStroke()
  arrow.stroke()

  let hint = "将码哨（Codewhistle）拖到 Applications 文件夹即可安装" as NSString
  let style = NSMutableParagraphStyle()
  style.alignment = .center
  hint.draw(
    in: NSRect(x: 0, y: 318, width: size.width, height: 24),
    withAttributes: [
      .font: NSFont.systemFont(ofSize: 15, weight: .medium),
      .foregroundColor: color(0x5B6475), .paragraphStyle: style,
    ])
}

let args = CommandLine.arguments
guard args.count >= 2 else {
  FileHandle.standardError.write("usage: make-dmg-background.swift <output.png> [scale]\n".data(using: .utf8)!)
  exit(2)
}
let scale = args.count >= 3 ? CGFloat(Double(args[2]) ?? 1) : 1
let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
  bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size  // points, so a 2x rep carries 144 dpi and Finder shows it at window size
NSGraphicsContext.saveGraphicsState()
// The context maps points to pixels via rep.size. Flipped: Finder positions icons from the
// window's top-left, so draw in the same coordinates.
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSImage(size: size, flipped: true) { _ in draw(); return true }
  .draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[1]))
