// 生成 App 图标：swift tools/make-icon.swift <输出目录>
// 产物：<输出目录>/AppIcon.icns（以及中间的 AppIcon.iconset）
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S: CGFloat = 1024

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 图标网格：824×824 圆角方块居中，留出阴影空间
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // 深色渐变底
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(red: 0.16, green: 0.19, blue: 0.27, alpha: 1).cgColor,
                                 NSColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // 顶部一条「状态栏」
    let barRect = CGRect(x: body.minX, y: body.maxY - 128, width: body.width, height: 128)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.07).cgColor); ctx.fill(barRect)
    for (i, a) in [0.55, 0.35, 0.35].enumerated() {
        let dot = CGRect(x: body.maxX - 120 - CGFloat(i) * 62, y: barRect.midY - 18, width: 36, height: 36)
        ctx.setFillColor(NSColor(white: 1, alpha: a).cgColor); ctx.fillEllipse(in: dot)
    }

    // 三根柱子：CPU 绿 / 内存 蓝 / 硬盘 橙
    let cols: [(NSColor, CGFloat)] = [
        (NSColor(red: 0.20, green: 0.84, blue: 0.47, alpha: 1), 0.58),
        (NSColor(red: 0.27, green: 0.60, blue: 1.00, alpha: 1), 0.80),
        (NSColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 1), 0.42),
    ]
    let w: CGFloat = 150, gap: CGFloat = 62
    let x0 = body.midX - (3 * w + 2 * gap) / 2
    let base: CGFloat = body.minY + 120, top: CGFloat = barRect.minY - 70
    for (i, (c, h)) in cols.enumerated() {
        let x = x0 + CGFloat(i) * (w + gap)
        let track = CGRect(x: x, y: base, width: w, height: top - base)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: 34, cornerHeight: 34, transform: nil))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor); ctx.fillPath()
        let fill = CGRect(x: x, y: base, width: w, height: (top - base) * h)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 34, cornerHeight: 34, transform: nil)); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [c.blended(withFraction: 0.25, of: .white)!.cgColor, c.cgColor] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: fill.maxY), end: CGPoint(x: 0, y: fill.minY), options: [])
        ctx.restoreGState()
    }

    // 细高光边
    ctx.addPath(shape); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let master = render()
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func write(_ px: Int, _ name: String) {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.addRepresentation(master)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
for s in [16, 32, 128, 256, 512] {
    write(s, "icon_\(s)x\(s).png")
    write(s * 2, "icon_\(s)x\(s)@2x.png")
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("✓ \(outDir)/AppIcon.icns")
