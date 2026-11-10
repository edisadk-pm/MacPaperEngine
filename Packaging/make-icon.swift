// Draws the layers of Resources/AppIcon.icon, one set per appearance. macOS applies the tile shape,
// glass and shadows itself. Run:
//   swiftc -O -o /tmp/makeicon Packaging/make-icon.swift && /tmp/makeicon Resources/AppIcon.icon/Assets
import AppKit
import CoreImage

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let canvas: CGFloat = 1024

func color(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
}

func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

func makeBitmap() -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func exportLayer(_ name: String, draw: () -> Void) {
    let bitmap = makeBitmap()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    draw()
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try! bitmap.representation(using: .png, properties: [:])!
        .write(to: outputDirectory.appendingPathComponent("\(name).png"))
}

func polygon(_ points: [NSPoint]) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.close()
    path.lineJoinStyle = .round
    return path
}

/// Every foreground shape shares one origin and scale, so that the layers stay aligned.
func inArtSpace(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 512, yBy: 486)
    transform.scale(by: 1.04)
    transform.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// MARK: - Mountains

struct MountainStyle {
    var border: NSColor?
    var outline: NSColor?
    var top: NSColor
    var bottom: NSColor
    var snow: NSColor
    var bodyOpacity: CGFloat = 1
}

func drawMountains(_ style: MountainStyle) {
    let summit = point(-30, 248)
    let valley = point(112, 26)
    let shoulder = point(196, 118)
    let range = polygon([point(-318, -214), summit, valley, shoulder, point(330, -214)])
    let mainSnow = polygon([summit, point(66, 98), point(26, 46), point(-12, 102),
                            point(-52, 44), point(-92, 98), point(-141, 70)])
    let sideSnow = polygon([shoulder, point(224, 48), point(196, 76), point(176, 38), point(145, 62)])

    if let border = style.border {
        border.setStroke()
        range.lineWidth = 88
        range.stroke()
    }
    if style.outline == nil {
        // A soft, even silhouette. Drawing it as one group stops the fill and the stroke that
        // gives it the sticker's outer shape from doubling up where they overlap.
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.setAlpha(style.bodyOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSColor.white.setFill()
        NSColor.white.setStroke()
        range.fill()
        range.lineWidth = 50
        range.stroke()
        context.endTransparencyLayer()
        context.restoreGState()
    } else {
        NSGradient(colors: [style.top, style.bottom])!.draw(in: range, angle: -90)
    }

    style.snow.setFill()
    mainSnow.fill()
    sideSnow.fill()

    if let outline = style.outline {
        outline.setStroke()
        mainSnow.lineWidth = 15
        mainSnow.stroke()
        sideSnow.lineWidth = 15
        sideSnow.stroke()
        range.lineWidth = 26
        range.stroke()
    }
}

// MARK: - Sun and moon

let discRect = NSRect(x: -292, y: 62, width: 168, height: 168)

func drawDisc(ring: NSColor?, fill: () -> Void) {
    let disc = NSBezierPath(ovalIn: discRect)
    if let ring {
        ring.setStroke()
        disc.lineWidth = 46
        disc.stroke()
    }
    NSGraphicsContext.saveGraphicsState()
    disc.addClip()
    fill()
    NSGraphicsContext.restoreGraphicsState()
}

func drawSun() {
    drawDisc(ring: .white) {
        NSGradient(colors: [color(255, 222, 92), color(255, 174, 46)])!.draw(in: discRect, angle: -90)
    }
}

func drawMoon() {
    drawDisc(ring: color(46, 62, 124)) {
        NSGradient(colors: [color(255, 248, 222), color(226, 222, 206)])!.draw(in: discRect, angle: -90)
        color(196, 194, 184, 0.75).setFill()
        for crater in [NSRect(x: -258, y: 150, width: 46, height: 46),
                       NSRect(x: -200, y: 104, width: 34, height: 34),
                       NSRect(x: -196, y: 176, width: 24, height: 24)] {
            NSBezierPath(ovalIn: crater).fill()
        }
    }
}

// MARK: - Sky

/// White puffs on a clear canvas, blurred so that they read as cloud rather than circles.
func clouds(_ puffs: [NSRect], blur: Double) -> CGImage {
    let bitmap = makeBitmap()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    puffs.forEach { NSBezierPath(ovalIn: $0).fill() }
    NSGraphicsContext.restoreGraphicsState()

    let input = CIImage(bitmapImageRep: bitmap)!
    let blurred = input.applyingGaussianBlur(sigma: blur).cropped(to: input.extent)
    return CIContext().createCGImage(blurred, from: input.extent)!
}

let upperCloud = [NSRect(x: 620, y: 780, width: 360, height: 250),
                  NSRect(x: 770, y: 640, width: 320, height: 290),
                  NSRect(x: 500, y: 880, width: 290, height: 190)]
let lowerCloud = [NSRect(x: -30, y: -30, width: 350, height: 205),
                  NSRect(x: 135, y: -40, width: 255, height: 180),
                  NSRect(x: 45, y: 55, width: 205, height: 165),
                  NSRect(x: 310, y: -45, width: 205, height: 116),
                  NSRect(x: 445, y: -50, width: 120, height: 60)]

func drawClouds(upper: CGFloat, lower: CGFloat) {
    let context = NSGraphicsContext.current!.cgContext
    let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    context.setAlpha(upper)
    context.draw(clouds(upperCloud, blur: 52), in: bounds)
    context.setAlpha(lower)
    context.draw(clouds(lowerCloud, blur: 26), in: bounds)
    context.setAlpha(1)
}

func drawStars() {
    let stars: [(CGFloat, CGFloat, CGFloat)] = [
        (120, 880, 7), (250, 960, 5), (430, 905, 8), (540, 965, 4), (700, 900, 6), (870, 950, 7),
        (930, 800, 5), (820, 720, 4), (640, 800, 5), (360, 830, 4), (80, 760, 4), (965, 640, 5),
    ]
    for (x, y, radius) in stars {
        color(255, 255, 255, 0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
    }
}

// MARK: - Export

let blueOutline = color(24, 146, 232)

exportLayer("mountains") {
    inArtSpace {
        drawMountains(MountainStyle(border: .white, outline: blueOutline,
                                    top: color(190, 226, 255), bottom: color(116, 190, 246), snow: .white))
    }
}
exportLayer("mountains-dark") {
    inArtSpace {
        drawMountains(MountainStyle(border: color(46, 62, 124), outline: color(142, 186, 244),
                                    top: color(70, 100, 182), bottom: color(36, 54, 118),
                                    snow: color(236, 244, 255)))
    }
}
// Tinted icons are built from brightness alone, so these use white at different strengths.
exportLayer("mountains-tinted") {
    inArtSpace {
        drawMountains(MountainStyle(border: nil, outline: nil,
                                    top: .white, bottom: .white, snow: .white, bodyOpacity: 0.58))
    }
}
exportLayer("sun") { inArtSpace(drawSun) }
exportLayer("moon") { inArtSpace(drawMoon) }
exportLayer("disc-tinted") {
    inArtSpace {
        drawDisc(ring: nil) {
            NSColor.white.setFill()
            discRect.fill()
        }
    }
}
exportLayer("clouds") { drawClouds(upper: 0.82, lower: 0.9) }
exportLayer("clouds-dark") {
    drawStars()
    drawClouds(upper: 0.13, lower: 0.17)
}
