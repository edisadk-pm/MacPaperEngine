// Draws the disk image window's background: a soft pastel gradient with grain and a faint grid,
// a hand-drawn arrow from the app to Applications, two built-in wallpapers as postage stamps, and
// a hint for the first launch. Run from the repository by Packaging/make-dmg.sh, which passes the
// output folder; writes background.png and background@2x.png.
import AppKit

// Taller than the window's content, so no edge shows whatever the title bar's height. Positions
// are from the top left, like Finder's: the icons sit at (165, 175) and (435, 175).
let size = NSSize(width: 600, height: 440)
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A soft round wash of colour, fading to nothing at its edge.
func blob(_ ctx: CGContext, center: CGPoint, radius: CGFloat, _ tint: NSColor) {
    let colors = [tint.cgColor, tint.withAlphaComponent(0).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius,
                           options: [])
}

/// Film grain, one random grey per pixel.
func grain(_ ctx: CGContext, scale: CGFloat, alpha: CGFloat) {
    let width = Int(size.width * scale), height = Int(size.height * scale)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt32 = 0x9E3779B9
    let a = UInt32(alpha * 255)
    for i in stride(from: 0, to: bytes.count, by: 4) {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        let v = UInt32(seed & 0xFF) * a / 255
        bytes[i] = UInt8(v); bytes[i + 1] = UInt8(v); bytes[i + 2] = UInt8(v); bytes[i + 3] = UInt8(a)
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    ctx.saveGState()
    ctx.setBlendMode(.overlay)
    ctx.draw(image, in: CGRect(origin: .zero, size: size))
    ctx.restoreGState()
}

/// A picture on a white stamp with perforated edges, tilted and casting a soft shadow.
func stamp(_ ctx: CGContext, image path: String, center: CGPoint, size stampSize: CGSize, degrees: CGFloat) {
    guard let picture = NSImage(contentsOfFile: path) else { return }
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: degrees * .pi / 180)
    let frame = CGRect(x: -stampSize.width / 2, y: -stampSize.height / 2, width: stampSize.width, height: stampSize.height)

    ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 10, color: NSColor(white: 0, alpha: 0.22).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(frame)
    // Bites out of every edge for the perforations.
    ctx.setBlendMode(.clear)
    let radius: CGFloat = 3.3, step: CGFloat = 10
    var x = frame.minX + step / 2
    while x < frame.maxX {
        for y in [frame.minY, frame.maxY] { ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)) }
        x += step
    }
    var y = frame.minY + step / 2
    while y < frame.maxY {
        for x in [frame.minX, frame.maxX] { ctx.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)) }
        y += step
    }
    ctx.setBlendMode(.normal)
    // The picture, filling its window in the stamp.
    let window = frame.insetBy(dx: 8, dy: 8)
    let source = picture.size
    let fill = max(window.width / source.width, window.height / source.height)
    let crop = CGSize(width: window.width / fill, height: window.height / fill)
    let from = NSRect(x: (source.width - crop.width) / 2, y: (source.height - crop.height) / 2, width: crop.width, height: crop.height)
    picture.draw(in: window, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// The arrow: one stroke that loops once on its way, then points at Applications.
func arrow(_ ctx: CGContext) {
    // A stretched trochoid makes the loop: x = t − b·sin t, y = b·cos t, for t from −π to π.
    let b: CGFloat = 1.9, sx: CGFloat = 18.5, sy: CGFloat = 10.5
    let origin = CGPoint(x: 296, y: 186)
    let path = CGMutablePath()
    let steps = 120
    for i in 0...steps {
        let t = -CGFloat.pi + 2 * .pi * CGFloat(i) / CGFloat(steps)
        let point = CGPoint(x: origin.x + sx * (t - b * sin(t)), y: origin.y + sy * b * cos(t))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    let end = CGPoint(x: origin.x + sx * .pi, y: origin.y - sy * b)
    let tip = CGPoint(x: end.x + 16, y: end.y + 1)
    path.addQuadCurve(to: tip, control: CGPoint(x: end.x + 9, y: end.y - 1))
    // The head, drawn as two quick strokes.
    path.move(to: CGPoint(x: tip.x - 14, y: tip.y - 12))
    path.addLine(to: tip)
    path.addLine(to: CGPoint(x: tip.x - 14, y: tip.y + 12))

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(color(0x22202B).cgColor)
    ctx.setLineWidth(4.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

/// A small pointer, as if about to drag.
func pointer(_ ctx: CGContext, at point: CGPoint) {
    let path = CGMutablePath()
    path.move(to: point)
    path.addLine(to: CGPoint(x: point.x + 34, y: point.y + 12))
    path.addLine(to: CGPoint(x: point.x + 18, y: point.y + 18))
    path.addLine(to: CGPoint(x: point.x + 12, y: point.y + 34))
    path.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: NSColor(white: 0, alpha: 0.18).cgColor)
    ctx.addPath(path)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(7)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(1.5)
    ctx.replacePathWithStrokedPath()
    ctx.addPath(path)
    ctx.clip(using: .winding)
    let colors = [color(0xF07BE8).cgColor, color(0xA875FF).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: point, end: CGPoint(x: point.x + 30, y: point.y + 30), options: [])
    ctx.restoreGState()
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = base.cgContext
    // Top-left origin, like Finder's icon positions.
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    // Cream, washed with sky blue, periwinkle, pink and peach.
    ctx.setFillColor(color(0xF8F1EA).cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))
    blob(ctx, center: CGPoint(x: 560, y: 30), radius: 300, color(0x7CC0FF, 0.85))
    blob(ctx, center: CGPoint(x: 330, y: 120), radius: 170, color(0xBFE0FF, 0.6))
    blob(ctx, center: CGPoint(x: 60, y: 250), radius: 250, color(0x8F96FF, 0.75))
    blob(ctx, center: CGPoint(x: 300, y: 300), radius: 230, color(0xFF86C8, 0.8))
    blob(ctx, center: CGPoint(x: 560, y: 330), radius: 200, color(0xFFC6A3, 0.7))
    blob(ctx, center: CGPoint(x: 120, y: 440), radius: 180, color(0xFFD9C2, 0.8))

    // A faint grid, like paper.
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.28).cgColor)
    ctx.setLineWidth(1 / scale)
    var line: CGFloat = 0
    while line <= max(size.width, size.height) {
        ctx.move(to: CGPoint(x: line, y: 0)); ctx.addLine(to: CGPoint(x: line, y: size.height))
        ctx.move(to: CGPoint(x: 0, y: line)); ctx.addLine(to: CGPoint(x: size.width, y: line))
        line += 20
    }
    ctx.strokePath()
    grain(ctx, scale: scale, alpha: 0.16)

    stamp(ctx, image: "Resources/Dynamic/previews/fuji.jpg", center: CGPoint(x: 92, y: 66), size: CGSize(width: 116, height: 84), degrees: -7)
    stamp(ctx, image: "Resources/Footage/previews/prism.jpg", center: CGPoint(x: 512, y: 334), size: CGSize(width: 112, height: 80), degrees: 9)
    arrow(ctx)
    pointer(ctx, at: CGPoint(x: 284, y: 262))

    // How to open it the first time, since the app isn't notarized.
    let text = "First launch: System Settings  ›  Privacy & Security  ›  Open Anyway" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: color(0x3A3550),
    ]
    let textSize = text.size(withAttributes: attributes)
    // High enough to stay clear of Finder's path bar, for people who show it.
    let pill = NSRect(x: 34, y: 300, width: textSize.width + 22, height: textSize.height + 10)
    NSColor(white: 1, alpha: 0.62).setFill()
    NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
    text.draw(at: NSPoint(x: pill.minX + 11, y: pill.minY + 5), withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: output.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: output.appendingPathComponent("background@2x.png"))
