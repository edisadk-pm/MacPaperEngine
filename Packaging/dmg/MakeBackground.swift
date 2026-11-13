// Draws the disk image window's background: a night sky like the app icon's, deep navy fading to
// indigo, with stars, a faint Milky Way and a shooting star; a hand-drawn arrow from the app to
// Applications; five built-in wallpapers as postage stamps, all inside the window even when Finder
// shows its path bar; light pills under the icons' names; and a hint for the first launch. Run
// from the repository by Packaging/make-dmg.sh, which passes the output folder; writes
// background.png and background@2x.png.
import AppKit

// Taller than the window's content, so no edge shows whatever the title bar's height. Positions
// are from the top left, like Finder's: the icons sit at (165, 175) and (435, 175).
let size = NSSize(width: 600, height: 510)
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The same random numbers on every run, so the sky doesn't change between builds.
struct Random {
    var state: UInt64
    mutating func next() -> CGFloat {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
    }
    mutating func between(_ low: CGFloat, _ high: CGFloat) -> CGFloat { low + (high - low) * next() }
    /// Bell-shaped around zero, mostly within ±2.
    mutating func gaussian() -> CGFloat {
        sqrt(-2 * log(max(next(), 1e-9))) * cos(2 * .pi * next())
    }
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

/// Where Finder writes the icons' names. Kept free of stars so the names stay easy to read.
let labels = [CGRect(x: 95, y: 230, width: 140, height: 30), CGRect(x: 365, y: 230, width: 140, height: 30)]

/// Stars: a scattering of faint ones, more along the Milky Way, and a few bright ones that twinkle.
func stars(_ ctx: CGContext) {
    var random = Random(state: 0x5EED_2026_1113)
    let tints: [UInt32] = [0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xDCE6FF, 0xFFF1D6]
    func dot(at point: CGPoint, radius: CGFloat, alpha: CGFloat) {
        guard !labels.contains(where: { $0.contains(point) }) else { return }
        let tint = tints[Int(random.next() * CGFloat(tints.count)) % tints.count]
        ctx.setFillColor(color(tint, alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }
    // All over, fainter towards the bottom where the sky is lighter.
    for _ in 0..<420 {
        let point = CGPoint(x: random.between(0, size.width), y: random.between(0, size.height))
        let fade = 1 - 0.55 * point.y / size.height
        let small = random.next()
        dot(at: point, radius: 0.3 + 0.8 * small * small, alpha: random.between(0.25, 0.9) * fade)
    }
    // Packed along the Milky Way, which rises from the bottom left to the top right.
    let start = CGPoint(x: -40, y: 420), end = CGPoint(x: 640, y: 0)
    let length = hypot(end.x - start.x, end.y - start.y)
    let along = CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
    let across = CGPoint(x: -along.y, y: along.x)
    for _ in 0..<520 {
        let t = random.between(0, length), offset = random.gaussian() * 34
        let point = CGPoint(x: start.x + along.x * t + across.x * offset, y: start.y + along.y * t + across.y * offset)
        dot(at: point, radius: random.between(0.25, 0.7), alpha: random.between(0.2, 0.7))
    }
}

/// A bright star: a soft glow with four thin points.
func twinkle(_ ctx: CGContext, at c: CGPoint, length: CGFloat, alpha: CGFloat = 1) {
    blob(ctx, center: c, radius: length * 1.6, color(0xC9D6FF, 0.35 * alpha))
    let w = length * 0.16
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x, y: c.y - length))
    path.addQuadCurve(to: CGPoint(x: c.x + length, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + length), control: CGPoint(x: c.x + w, y: c.y + w))
    path.addQuadCurve(to: CGPoint(x: c.x - length, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - length), control: CGPoint(x: c.x - w, y: c.y - w))
    ctx.addPath(path)
    ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)
    ctx.fillPath()
}

/// A shooting star: a streak that fades out behind a bright head.
func shootingStar(_ ctx: CGContext, from tail: CGPoint, to head: CGPoint) {
    ctx.saveGState()
    ctx.setLineCap(.round)
    let steps = 40
    for i in 0..<steps {
        let a = CGFloat(i) / CGFloat(steps), b = CGFloat(i + 1) / CGFloat(steps)
        ctx.move(to: CGPoint(x: tail.x + (head.x - tail.x) * a, y: tail.y + (head.y - tail.y) * a))
        ctx.addLine(to: CGPoint(x: tail.x + (head.x - tail.x) * b, y: tail.y + (head.y - tail.y) * b))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85 * b * b).cgColor)
        ctx.setLineWidth(0.4 + 1.4 * b)
        ctx.strokePath()
    }
    ctx.restoreGState()
    twinkle(ctx, at: head, length: 5)
}

/// A picture on a white stamp with perforated edges, tilted and casting a soft shadow.
func stamp(_ ctx: CGContext, image path: String, center: CGPoint, size stampSize: CGSize, degrees: CGFloat) {
    guard let picture = NSImage(contentsOfFile: path) else { fatalError("No picture at \(path)") }
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: degrees * .pi / 180)
    let frame = CGRect(x: -stampSize.width / 2, y: -stampSize.height / 2, width: stampSize.width, height: stampSize.height)

    ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 14, color: NSColor(white: 0, alpha: 0.5).cgColor)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(0xFBF8F2).cgColor)
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

/// A rounded pill of the stamps' paper, for text to sit on.
func paper(_ rect: CGRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -2)
    shadow.shadowBlurRadius = 8
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.set()
    color(0xFBF8F2, 0.92).setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
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
    // Chalk on the night sky, with a faint glow.
    ctx.setShadow(offset: .zero, blur: 8, color: color(0xB9C6FF, 0.55).cgColor)
    ctx.setStrokeColor(color(0xF4F1FF).cgColor)
    ctx.setLineWidth(4.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
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

    // Deep navy overhead, lightening to indigo towards the bottom, as in the app icon.
    let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                         colors: [color(0x070B22).cgColor, color(0x111A4A).cgColor, color(0x232A6E).cgColor] as CFArray,
                         locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    // Washes of blue, violet and a little magenta, like faint nebulae.
    blob(ctx, center: CGPoint(x: 560, y: 20), radius: 300, color(0x2F5BD8, 0.35))
    blob(ctx, center: CGPoint(x: 40, y: 250), radius: 260, color(0x5B3FC4, 0.35))
    blob(ctx, center: CGPoint(x: 330, y: 420), radius: 280, color(0xA24BB0, 0.3))
    blob(ctx, center: CGPoint(x: 580, y: 360), radius: 220, color(0x3D6FD6, 0.25))

    // The Milky Way: a soft band of light from the bottom left to the top right.
    ctx.saveGState()
    ctx.translateBy(x: 300, y: 210)
    ctx.rotate(by: atan2(-420, 680))
    let band = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xB8B4FF, 0).cgColor, color(0xB8B4FF, 0.13).cgColor, color(0xB8B4FF, 0).cgColor] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(band, start: CGPoint(x: 0, y: -90), end: CGPoint(x: 0, y: 90), options: [])
    ctx.restoreGState()

    // A faint grid, like paper.
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.04).cgColor)
    ctx.setLineWidth(1 / scale)
    var line: CGFloat = 0
    while line <= max(size.width, size.height) {
        ctx.move(to: CGPoint(x: line, y: 0)); ctx.addLine(to: CGPoint(x: line, y: size.height))
        ctx.move(to: CGPoint(x: 0, y: line)); ctx.addLine(to: CGPoint(x: size.width, y: line))
        line += 20
    }
    ctx.strokePath()
    stars(ctx)
    for (point, length) in [(CGPoint(x: 214, y: 92), 6.0), (CGPoint(x: 420, y: 118), 4.5), (CGPoint(x: 574, y: 196), 5.5),
                            (CGPoint(x: 236, y: 372), 4.0), (CGPoint(x: 384, y: 350), 4.5), (CGPoint(x: 400, y: 40), 3.5)] {
        twinkle(ctx, at: point, length: length)
    }
    shootingStar(ctx, from: CGPoint(x: 96, y: 150), to: CGPoint(x: 40, y: 178))
    grain(ctx, scale: scale, alpha: 0.1)

    stamp(ctx, image: "Resources/Dynamic/previews/fuji.jpg", center: CGPoint(x: 92, y: 66), size: CGSize(width: 116, height: 84), degrees: -7)
    stamp(ctx, image: "Resources/Footage/previews/starburst.jpg", center: CGPoint(x: 312, y: 46), size: CGSize(width: 84, height: 62), degrees: 5)
    stamp(ctx, image: "Resources/Dynamic/previews/alps.jpg", center: CGPoint(x: 526, y: 74), size: CGSize(width: 108, height: 78), degrees: 8)
    stamp(ctx, image: "Resources/Footage/previews/crimson.jpg", center: CGPoint(x: 78, y: 362), size: CGSize(width: 100, height: 72), degrees: -10)
    stamp(ctx, image: "Resources/Footage/previews/prism.jpg", center: CGPoint(x: 522, y: 360), size: CGSize(width: 104, height: 74), degrees: 9)
    arrow(ctx)

    // Finder writes the icons' names in black even in Dark Mode, so each sits on a pill of the
    // stamps' paper, sized to the name in Finder's 13-point label font.
    for (name, x) in [("MacPaperEngine", 165.0), ("Applications", 435.0)] {
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 20
        paper(CGRect(x: x - width / 2, y: 238, width: width, height: 23))
    }

    // How to open it the first time, since the app isn't notarized, centred on the same paper.
    let text = "First launch: System Settings › Privacy & Security › Open Anyway" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: color(0x262A55),
    ]
    let textSize = text.size(withAttributes: attributes)
    // Between the names and the bottom stamps, clear of both.
    let pillWidth = textSize.width + 22
    let pill = NSRect(x: (size.width - pillWidth) / 2, y: 280, width: pillWidth, height: textSize.height + 10)
    paper(pill)
    text.draw(at: NSPoint(x: pill.minX + 11, y: pill.minY + 5), withAttributes: attributes)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: output.appendingPathComponent("background.png"))
try! render(scale: 2).write(to: output.appendingPathComponent("background@2x.png"))
