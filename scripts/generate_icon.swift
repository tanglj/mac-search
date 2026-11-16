import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()
let plate = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 210, yRadius: 210)
NSColor(calibratedRed: 0.13, green: 0.44, blue: 0.33, alpha: 1).setFill()
plate.fill()
NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
plate.lineWidth = 7
plate.stroke()
let document = NSBezierPath(roundedRect: NSRect(x: 260, y: 255, width: 430, height: 540), xRadius: 42, yRadius: 42)
NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
document.fill()
NSColor.white.setStroke()
document.lineWidth = 25
document.stroke()
for offset in [0.0, 78.0] {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 340, y: 695 - offset))
    line.line(to: NSPoint(x: 585, y: 695 - offset))
    line.lineWidth = 22
    line.lineCapStyle = .round
    line.stroke()
}
let circle = NSBezierPath(ovalIn: NSRect(x: 410, y: 235, width: 270, height: 270))
NSColor(calibratedRed: 0.13, green: 0.44, blue: 0.33, alpha: 1).setFill()
circle.fill()
NSColor.white.setStroke()
circle.lineWidth = 40
circle.stroke()
let handle = NSBezierPath()
handle.move(to: NSPoint(x: 650, y: 265))
handle.line(to: NSPoint(x: 770, y: 150))
handle.lineWidth = 50
handle.lineCapStyle = .round
handle.stroke()
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法生成应用图标")
}
try png.write(to: URL(fileURLWithPath: output))
