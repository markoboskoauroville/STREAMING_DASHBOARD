// make_icon.swift <version> <out.png>: the icon of Streaming Dashboard (Mantra), drawn in code (swift-apps.md rule 4):
// what the window shows — the chain PHONE · MAC · VM · SITE as four lights on one line, a sparkline of the speed under it,
// on the dark ground, the version at the bottom (version-visible.md). Run by build.sh on GitHub's runner.
import AppKit
let a = CommandLine.arguments
let v = a.count > 1 ? a[1] : "1", out = a.count > 2 ? a[2] : "icon_1024.png"
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185).fill()
// the chain: a hairline and four lights
let y: CGFloat = 690
let line = NSBezierPath(); line.move(to: NSPoint(x: 230, y: y)); line.line(to: NSPoint(x: 794, y: y))
line.lineWidth = 10; NSColor(white: 0.35, alpha: 1).setStroke(); line.stroke()
let lights: [NSColor] = [NSColor(red: 0.2, green: 0.82, blue: 0.48, alpha: 1), NSColor(red: 0.2, green: 0.82, blue: 0.48, alpha: 1),
                         NSColor(red: 0.2, green: 0.82, blue: 0.48, alpha: 1), NSColor(red: 0.83, green: 0.69, blue: 0.22, alpha: 1)]
for (i, c) in lights.enumerated() {
    let x = 230 + CGFloat(i) * 188
    c.setFill(); NSBezierPath(ovalIn: NSRect(x: x - 42, y: y - 42, width: 84, height: 84)).fill()
}
// the sparkline
let pts: [CGFloat] = [0.30, 0.42, 0.36, 0.55, 0.50, 0.68, 0.60, 0.78, 0.72, 0.88]
let sp = NSBezierPath()
for (i, p) in pts.enumerated() {
    let pt = NSPoint(x: 230 + CGFloat(i) * 564 / CGFloat(pts.count - 1), y: 330 + p * 220)
    if i == 0 { sp.move(to: pt) } else { sp.line(to: pt) }
}
sp.lineWidth = 26; sp.lineCapStyle = .round; sp.lineJoinStyle = .round; NSColor.white.setStroke(); sp.stroke()
let base = NSBezierPath(); base.move(to: NSPoint(x: 230, y: 320)); base.line(to: NSPoint(x: 794, y: 320))
base.lineWidth = 6; NSColor(white: 0.35, alpha: 1).setStroke(); base.stroke()
let p = NSMutableParagraphStyle(); p.alignment = .center
("v" + v as NSString).draw(in: NSRect(x: 100, y: 150, width: 824, height: 110),
    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 84, weight: .bold), .foregroundColor: NSColor(white: 0.75, alpha: 1), .paragraphStyle: p])
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
