// Renders the Core Monitor app icon: a glowing chip with a live CPU trace. Run: swift make_icon.swift <out.png>
import AppKit
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// macOS squircle tile with deep navy -> violet gradient
let inset: CGFloat = 100, tile = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
let sh = NSShadow(); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -12); sh.shadowColor = .black.withAlphaComponent(0.45); sh.set()
NSColor.black.setFill(); tilePath.fill()
ctx.restoreGState()
tilePath.addClip()
NSGradient(colors: [NSColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 1), NSColor(red: 0.20, green: 0.08, blue: 0.36, alpha: 1)])!.draw(in: tile, angle: -60)
// faint grid
NSColor.white.withAlphaComponent(0.05).setStroke()
for i in stride(from: tile.minX, through: tile.maxX, by: 64) { let p = NSBezierPath(); p.move(to: NSPoint(x: i, y: tile.minY)); p.line(to: NSPoint(x: i, y: tile.maxY)); p.lineWidth = 2; p.stroke() }
for i in stride(from: tile.minY, through: tile.maxY, by: 64) { let p = NSBezierPath(); p.move(to: NSPoint(x: tile.minX, y: i)); p.line(to: NSPoint(x: tile.maxX, y: i)); p.lineWidth = 2; p.stroke() }
// chip pins
let chip = CGRect(x: 312, y: 312, width: 400, height: 400)
let pinColor = NSColor(red: 0.55, green: 0.85, blue: 1, alpha: 0.9)
pinColor.setFill()
for k in 0..<5 {
    let o = chip.minX + 60 + CGFloat(k) * 70
    for r in [CGRect(x: o - 12, y: chip.maxY, width: 24, height: 58), CGRect(x: o - 12, y: chip.minY - 58, width: 24, height: 58),
              CGRect(x: chip.minX - 58, y: o - 12, width: 58, height: 24), CGRect(x: chip.maxX, y: o - 12, width: 58, height: 24)] {
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    }
}
// chip body
let body = NSBezierPath(roundedRect: chip, xRadius: 56, yRadius: 56)
NSGradient(colors: [NSColor(red: 0.13, green: 0.16, blue: 0.28, alpha: 1), NSColor(red: 0.07, green: 0.09, blue: 0.18, alpha: 1)])!.draw(in: body, angle: -90)
body.lineWidth = 10; pinColor.setStroke(); body.stroke()
// CPU trace with glow
let pts: [CGFloat] = [0.30, 0.32, 0.28, 0.45, 0.40, 0.78, 0.22, 0.55, 0.50, 0.62, 0.58]
let trace = NSBezierPath(); trace.lineWidth = 26; trace.lineCapStyle = .round; trace.lineJoinStyle = .round
let g = chip.insetBy(dx: 60, dy: 80)
for (i, v) in pts.enumerated() {
    let p = NSPoint(x: g.minX + g.width * CGFloat(i) / CGFloat(pts.count - 1), y: g.minY + g.height * v)
    i == 0 ? trace.move(to: p) : trace.line(to: p)
}
ctx.saveGState()
let glow = NSShadow(); glow.shadowBlurRadius = 40; glow.shadowOffset = .zero; glow.shadowColor = NSColor(red: 0.2, green: 1, blue: 0.75, alpha: 1); glow.set()
NSColor(red: 0.35, green: 1, blue: 0.80, alpha: 1).setStroke(); trace.stroke()
ctx.restoreGState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
