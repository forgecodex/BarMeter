// 生成安装镜像窗口背景：swift tools/make-dmg-bg.swift Resources/dmg-background.png
import AppKit
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let W = 640, H = 400
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(red: 0.965, green: 0.969, blue: 0.976, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

func text(_ s: String, _ size: CGFloat, _ y: CGFloat, _ color: NSColor, bold: Bool = false) {
    let ps = NSMutableParagraphStyle(); ps.alignment = .center
    let a: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                                            .foregroundColor: color, .paragraphStyle: ps]
    NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: y, width: CGFloat(W), height: size + 8))
}
text("把 BarMeter 拖到「应用程序」即可安装", 17, 330, NSColor(white: 0.15, alpha: 1), bold: true)

// 箭头（Finder 坐标 y=190 → 位图 y≈210）
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 255, y: 210)); arrow.line(to: NSPoint(x: 375, y: 210))
arrow.lineWidth = 5; arrow.lineCapStyle = .round
NSColor(red: 0.27, green: 0.55, blue: 0.95, alpha: 1).set(); arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 388, y: 210)); head.line(to: NSPoint(x: 366, y: 224)); head.line(to: NSPoint(x: 366, y: 196)); head.close()
head.fill()

text("首次打开如提示「无法验证开发者」：", 12, 62, NSColor(white: 0.35, alpha: 1))
text("系统设置 → 隐私与安全性 → 往下翻，点「仍要打开」", 12, 42, NSColor(white: 0.35, alpha: 1))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("✓ \(out)")
