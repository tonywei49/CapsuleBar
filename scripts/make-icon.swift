// Draws the CapsuleBar app icon (1024×1024 PNG).
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Body: macOS icon grid — 824pt rounded square centered, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x1B1E26))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
// Background: deep graphite-to-indigo gradient with a cool glow under the capsule.
let bg = CGGradient(colorsSpace: space, colors: [color(0x2E3446), color(0x12141B)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let glow = CGGradient(colorsSpace: space, colors: [color(0x5B8CFF, 0.35), color(0x5B8CFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 650), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 650), endRadius: 420, options: [])

// "Expanded list" rows fading downward.
for (i, accent) in [0xFF9F43, 0x34C759, 0x5AC8FA].enumerated() {
    let y = 470 - CGFloat(i) * 118
    let alpha = 0.9 - CGFloat(i) * 0.25
    let row = CGRect(x: 200, y: y, width: 624, height: 84)
    ctx.addPath(CGPath(roundedRect: row, cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.07 * alpha + 0.02))
    ctx.fillPath()
    // app dot
    ctx.setFillColor(color(UInt32(accent), alpha))
    ctx.fillEllipse(in: CGRect(x: 228, y: y + 20, width: 44, height: 44))
    // name bar + value bar
    ctx.addPath(CGPath(roundedRect: CGRect(x: 298, y: y + 33, width: 250 - CGFloat(i) * 40, height: 18),
                       cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.55 * alpha))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 700, y: y + 33, width: 92, height: 18),
                       cornerWidth: 9, cornerHeight: 9, transform: nil))
    ctx.setFillColor(color(0xFFFFFF, 0.3 * alpha))
    ctx.fillPath()
}
ctx.restoreGState()

// The capsule ("dynamic island").
let capsule = CGRect(x: 232, y: 618, width: 560, height: 150)
let capsulePath = CGPath(roundedRect: capsule, cornerWidth: 75, cornerHeight: 75, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.6))
ctx.addPath(capsulePath)
ctx.setFillColor(color(0x000000))
ctx.fillPath()
ctx.restoreGState()
// subtle rim highlight
ctx.addPath(capsulePath)
ctx.setStrokeColor(color(0xFFFFFF, 0.14))
ctx.setLineWidth(3)
ctx.strokePath()

// Left: three app dots.
for (i, hex) in [0xFF9F43, 0x34C759, 0x5AC8FA].enumerated() {
    ctx.setFillColor(color(UInt32(hex)))
    ctx.fillEllipse(in: CGRect(x: 300 + CGFloat(i) * 62, y: 670, width: 46, height: 46))
}

// Right: ring gauge.
let center = CGPoint(x: 704, y: 693)
ctx.setLineWidth(14)
ctx.setLineCap(.round)
ctx.setStrokeColor(color(0xFFFFFF, 0.18))
ctx.addArc(center: center, radius: 34, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()
ctx.setStrokeColor(color(0x30D158))
ctx.addArc(center: center, radius: 34, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * 0.68, clockwise: true)
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
