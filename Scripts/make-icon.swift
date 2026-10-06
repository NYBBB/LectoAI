import AppKit

// 原生矢量绘制；从同一设计渲染全部尺寸，避免缩放后的边缘模糊。
let output = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func render(_ pixels: Int, to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 210, yRadius: 210)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = color(0.10, 0.24, 0.42, 0.23); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -14); shadow.set()
    color(0.89, 0.94, 0.99).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(0.78, 0.87, 0.98), color(0.96, 0.99, 1), .white])!.draw(in: tile, angle: 70)
    color(1, 1, 1, 0.92).setStroke(); tile.lineWidth = 5; tile.stroke()
    NSGraphicsContext.saveGraphicsState(); tile.addClip()
    let glow = NSBezierPath(ovalIn: NSRect(x: 175, y: 100, width: 690, height: 690))
    NSGradient(colors: [color(0.23, 0.65, 1, 0.24), color(0.74, 0.89, 1, 0)])!.draw(in: glow, relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()
    // 玻璃字幕气泡与四道声波，组合成可在 Dock 中识别的单一符号。
    let glass = NSBezierPath(roundedRect: NSRect(x: 208, y: 262, width: 608, height: 498), xRadius: 140, yRadius: 140)
    NSGraphicsContext.saveGraphicsState()
    let innerShadow = NSShadow(); innerShadow.shadowColor = color(0.1, 0.35, 0.66, 0.14); innerShadow.shadowBlurRadius = 32; innerShadow.shadowOffset = NSSize(width: 0, height: -12); innerShadow.set()
    color(1, 1, 1, 0.48).setFill(); glass.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [color(1, 1, 1, 0.25), color(1, 1, 1, 0.90)])!.draw(in: glass, angle: 90)
    color(1, 1, 1, 0.9).setStroke(); glass.lineWidth = 4; glass.stroke()
    let bars: [(CGFloat, CGFloat, CGFloat)] = [(315, 440, 148), (423, 368, 292), (531, 410, 210), (639, 459, 113)]
    for (x, y, height) in bars {
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 70, height: height), xRadius: 35, yRadius: 35)
        NSGradient(colors: [color(0.035, 0.29, 0.83), color(0.12, 0.58, 1)])!.draw(in: bar, angle: 90)
        color(0.42, 0.76, 1, 0.7).setStroke(); bar.lineWidth = 2; bar.stroke()
    }
    let tail = NSBezierPath(); tail.move(to: NSPoint(x: 266, y: 294)); tail.curve(to: NSPoint(x: 248, y: 215), controlPoint1: NSPoint(x: 272, y: 256), controlPoint2: NSPoint(x: 255, y: 234)); tail.curve(to: NSPoint(x: 350, y: 270), controlPoint1: NSPoint(x: 293, y: 218), controlPoint2: NSPoint(x: 323, y: 249)); tail.close()
    color(0.72, 0.84, 0.97, 0.85).setFill(); tail.fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        try render(size * scale, to: directory.appendingPathComponent(name))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let catalog: [String: Any] = ["images": entries, "info": ["author": "LectoAI", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("Contents.json"))
