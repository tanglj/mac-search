import AppKit

// 两款工具共用的图标语言；坐标基于 1024 pt，输出固定 1024 px。
let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.png"
let variant = CommandLine.arguments.dropFirst(2).first ?? "search"
guard ["search", "clean"].contains(variant) else { fatalError("图标类型必须为 search 或 clean") }
let isSearch = variant == "search"
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current!.imageInterpolation = .high
NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: radius, yRadius: radius)
}
func fill(_ path: NSBezierPath, _ value: NSColor) { value.setFill(); path.fill() }
func gradient(_ path: NSBezierPath, _ colors: [NSColor], _ angle: CGFloat = 90) {
    NSGradient(colors: colors)!.draw(in: path, angle: angle)
}
func shadowed(_ draw: () -> Void, blur: CGFloat = 22, offset: CGFloat = -12) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.01, 0.12, 0.24, 0.28)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offset)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}
func line(_ points: [NSPoint], width: CGFloat, ink: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    ink.setStroke()
    path.stroke()
}
func sparkle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: y + radius))
    for (dx, dy, cx, cy) in [(1.0, 0.0, 0.23, 0.23), (0, -1, 0.23, -0.23), (-1, 0, -0.23, -0.23), (0, 1, -0.23, 0.23)] {
        let control = NSPoint(x: x + radius * cx, y: y + radius * cy)
        path.curve(to: NSPoint(x: x + radius * dx, y: y + radius * dy), controlPoint1: control, controlPoint2: control)
    }
    path.close()
    return path
}
let bottom = isSearch ? color(0.10, 0.29, 0.82) : color(0.02, 0.43, 0.43)
let top = isSearch ? color(0.17, 0.72, 0.97) : color(0.20, 0.82, 0.66)
let accent = isSearch ? color(0.13, 0.43, 0.78) : color(0.02, 0.49, 0.43)
let tile = rounded(100, 100, 824, 824, 186)
shadowed { fill(tile, bottom) }
gradient(tile, [bottom, top], 65)
NSGraphicsContext.saveGraphicsState()
tile.addClip()
fill(NSBezierPath(ovalIn: NSRect(x: -50, y: 610, width: 1080, height: 600)), color(1, 1, 1, 0.055))
NSGraphicsContext.restoreGraphicsState()
color(1, 1, 1, 0.24).setStroke()
tile.lineWidth = 2
tile.stroke()
let porcelain = [color(0.81, 0.91, 0.98), color(1, 1, 1)]
if isSearch {
    // 文件与放大镜：保留纸张轮廓，镜片覆盖右下角。
    let paper = rounded(260, 282, 380, 490, 46)
    shadowed { fill(paper, .white) }
    gradient(paper, porcelain)
    for (y, width) in [(680.0, 210.0), (610, 164), (540, 110)] {
        line([NSPoint(x: 330, y: y), NSPoint(x: 330 + width, y: y)], width: 22, ink: accent.withAlphaComponent(0.45))
    }
    shadowed({
        line([NSPoint(x: 647, y: 352), NSPoint(x: 758, y: 241)], width: 66, ink: color(0.88, 0.96, 1))
        let lens = NSBezierPath(ovalIn: NSRect(x: 445, y: 338, width: 254, height: 254))
        fill(lens, color(0.08, 0.36, 0.70))
        gradient(lens, [color(0.11, 0.43, 0.78), color(0.28, 0.75, 0.94)], 65)
        color(0.97, 1, 1).setStroke()
        lens.lineWidth = 43
        lens.stroke()
        line([NSPoint(x: 500, y: 482), NSPoint(x: 541, y: 523)], width: 14, ink: color(1, 1, 1, 0.55))
    }, blur: 18, offset: -10)
} else {
    // 扫刷：倾斜的手柄、刷箍和展开的刷毛构成明确清扫动作。
    NSGraphicsContext.saveGraphicsState()
    let rotation = NSAffineTransform()
    rotation.translateX(by: 512, yBy: 510)
    rotation.rotate(byDegrees: -34)
    rotation.concat()
    let handle = rounded(-31, -75, 62, 367, 31)
    shadowed { fill(handle, .white) }
    gradient(handle, porcelain, 0)
    let bristles = NSBezierPath()
    bristles.move(to: NSPoint(x: -112, y: -58))
    bristles.line(to: NSPoint(x: 112, y: -58))
    bristles.curve(to: NSPoint(x: 172, y: -254), controlPoint1: NSPoint(x: 120, y: -140), controlPoint2: NSPoint(x: 144, y: -208))
    bristles.curve(to: NSPoint(x: -172, y: -254), controlPoint1: NSPoint(x: 80, y: -286), controlPoint2: NSPoint(x: -80, y: -286))
    bristles.curve(to: NSPoint(x: -112, y: -58), controlPoint1: NSPoint(x: -144, y: -208), controlPoint2: NSPoint(x: -120, y: -140))
    bristles.close()
    shadowed { fill(bristles, .white) }
    gradient(bristles, porcelain)
    for x in [-83.0, 0, 83] {
        line([NSPoint(x: x * 0.68, y: -140), NSPoint(x: x, y: -241)], width: 13, ink: accent.withAlphaComponent(0.38))
    }
    let band = rounded(-119, -108, 238, 76, 24)
    gradient(band, [color(0.46, 0.90, 0.82), color(0.78, 1, 0.94)])
    NSGraphicsContext.restoreGraphicsState()
    shadowed { fill(sparkle(704, 658, 85), .white) }
    fill(sparkle(319, 698, 35), color(0.88, 1, 0.98))
}
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try bitmap.representation(using: .png, properties: [:])!.write(to: url)
print(url.path)
