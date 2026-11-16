// Composes a README screenshot: a capsule capture placed at the top center of a mock
// wallpaper with a menu bar. Captures are @2x, so 1pt = 2px everywhere here.
// Usage: swift scripts/compose-shot.swift <capture.png> <output.png> <width> <height>
import AppKit

let args = CommandLine.arguments
guard args.count >= 5, let overlay = NSImage(contentsOfFile: args[1]),
      let width = Int(args[3]), let height = Int(args[4]) else {
    print("usage: compose-shot.swift <capture.png> <output.png> <width> <height>")
    exit(1)
}
let W = CGFloat(width), H = CGFloat(height)
let bar: CGFloat = 64   // menu bar height in px (@2x)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Wallpaper
let colors = [NSColor(srgbRed: 0.12, green: 0.24, blue: 0.45, alpha: 1).cgColor,
              NSColor(srgbRed: 0.27, green: 0.20, blue: 0.52, alpha: 1).cgColor,
              NSColor(srgbRed: 0.62, green: 0.30, blue: 0.48, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

// Menu bar
ctx.setFillColor(NSColor(white: 1, alpha: 0.14).cgColor)
ctx.fill(CGRect(x: 0, y: H - bar, width: W, height: bar))
let menuFont = NSFont.systemFont(ofSize: 26, weight: .regular)
let boldFont = NSFont.systemFont(ofSize: 26, weight: .bold)
var x: CGFloat = 40
for (i, title) in ["Finder", "File", "Edit", "View", "Go"].enumerated() {
    let str = NSAttributedString(string: title, attributes: [.font: i == 0 ? boldFont : menuFont,
                                                             .foregroundColor: NSColor.white])
    str.draw(at: NSPoint(x: x, y: H - bar + 15))
    x += str.size().width + 40
}
let clock = NSAttributedString(string: "Mon 15:30", attributes: [.font: menuFont, .foregroundColor: NSColor.white])
let clockX = W - 40 - clock.size().width
clock.draw(at: NSPoint(x: clockX, y: H - bar + 15))
for i in 0..<5 {
    let r = CGRect(x: clockX - 70 - CGFloat(i) * 56, y: H - bar + 18, width: 28, height: 28)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil))
    ctx.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor)
    ctx.fillPath()
}

// Capsule capture, top-centered
let size = overlay.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? overlay.size
overlay.draw(in: NSRect(x: (W - size.width) / 2, y: H - size.height, width: size.width, height: size.height))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
