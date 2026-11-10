import AppKit
import ImageIO
import MacPaperCore

/// A picture, or a dynamic wallpaper showing one of its pictures. Each picture is decoded once,
/// straight to the display's pixel size and already scaled, so the only memory held is one
/// screen-sized bitmap. Nothing runs between changes: no timers, no display link.
final class StillContent: WallpaperContent {
    var layer: CALayer { imageLayer }
    var onReady: (() -> Void)?
    let isAnimated = false

    private let imageLayer = CALayer()
    private let url: URL
    private let schedule: DynamicSchedule?
    private var scaling: Scaling
    private var pixelSize: CGSize
    private var scale: CGFloat

    private var shown: (index: Int, size: CGSize, scaling: Scaling)?
    private var generation = 0
    private var stopped = false
    private var lastCheck = 0.0
    private var appearanceObservation: NSKeyValueObservation?

    private static let queue = DispatchQueue(label: "app.macpaper.still", qos: .userInitiated)
    private static let checkInterval: CFTimeInterval = 30
    private static let changeFade: CFTimeInterval = 2

    init(url: URL, dynamic: Bool, bounds: CGRect, scale: CGFloat, settings: WallpaperSettings) {
        self.url = url
        schedule = dynamic ? DynamicSchedule.read(from: url) : nil
        scaling = settings.scaling
        pixelSize = bounds.size
        self.scale = scale
        imageLayer.contentsGravity = .resize
        imageLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        imageLayer.isOpaque = true
        imageLayer.actions = ["contents": NSNull()]
    }

    func start() {
        if schedule?.followsAppearance == true {
            appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh(force: true) }
            }
        }
        refresh(force: true)
    }

    func stop() {
        stopped = true
        onReady = nil
        appearanceObservation = nil
        generation += 1
        imageLayer.contents = nil
    }

    func setPaused(_ paused: Bool) {}

    func apply(settings: WallpaperSettings) {
        guard settings.scaling != scaling else { return }
        scaling = settings.scaling
        refresh(force: true)
    }

    func updateBacking(scale: CGFloat) {
        guard scale != self.scale else { return }
        self.scale = scale
        refresh(force: true)
    }

    func layout(in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        if bounds.size != pixelSize {
            pixelSize = bounds.size
            refresh(force: true)
        }
    }

    /// Called every couple of seconds by the engine's tick and after wake. Cheap: it only looks
    /// at the clock, and only every half minute.
    func recoverIfNeeded() {
        refresh(force: false)
    }

    // MARK: - Choosing and drawing

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func refresh(force: Bool) {
        guard !stopped else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastCheck > Self.checkInterval else { return }
        lastCheck = now

        let index = schedule?.frameIndex(dark: isDark) ?? -1
        let target = CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
        guard target.width >= 2, target.height >= 2 else { return }
        if let shown, shown.index == index, shown.size == target, shown.scaling == scaling { return }

        let firstFrame = shown == nil
        let changedPicture = shown.map { $0.index != index } ?? false
        shown = (index, target, scaling)
        generation += 1
        let ticket = generation
        let url = url
        let scaling = scaling

        Self.queue.async { [weak self] in
            let image = Self.render(url: url, index: index, size: target, scaling: scaling)
            DispatchQueue.main.async {
                guard let self, !self.stopped, ticket == self.generation else { return }
                guard let image else {
                    // Leaves the window clear rather than black, so the system wallpaper shows.
                    self.shown = nil
                    return
                }
                self.show(image, fade: changedPicture)
                if firstFrame { self.onReady?() }
                // Decoding a large original leaves big freed blocks behind; hand them back now.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
            }
        }
    }

    private func show(_ image: CGImage, fade: Bool) {
        if fade {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = Self.changeFade
            imageLayer.add(transition, forKey: "change")
        }
        imageLayer.contents = image
    }

    /// Decodes at the size it will be drawn, then lays it into a screen-sized bitmap, so the
    /// full-resolution original (often 6K) is never held.
    private static func render(url: URL, index: Int, size: CGSize, scaling: Scaling) -> CGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            let frame = index >= 0 && index < CGImageSourceGetCount(source)
                ? index
                : CGImageSourceGetPrimaryImageIndex(source)

            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Double,
                  var height = properties[kCGImagePropertyPixelHeight] as? Double,
                  width > 0, height > 0 else { return nil }
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
                swap(&width, &height)
            }

            let rect = drawRect(image: CGSize(width: width, height: height), in: size, scaling: scaling)
            let longestSide = max(rect.width, rect.height)
            let decoded = CGImageSourceCreateThumbnailAtIndex(source, frame, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(min(longestSide, max(width, height)).rounded(.up)),
            ] as CFDictionary)
            guard let decoded else { return nil }

            let space = decoded.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.draw(decoded, in: rect)
            return context.makeImage()
        }
    }

    private static func drawRect(image: CGSize, in target: CGSize, scaling: Scaling) -> CGRect {
        switch scaling {
        case .stretch:
            return CGRect(origin: .zero, size: target)
        case .fill, .fit:
            let ratioX = target.width / image.width
            let ratioY = target.height / image.height
            let factor = scaling == .fill ? max(ratioX, ratioY) : min(ratioX, ratioY)
            let size = CGSize(width: image.width * factor, height: image.height * factor)
            return CGRect(x: (target.width - size.width) / 2, y: (target.height - size.height) / 2,
                          width: size.width, height: size.height)
        }
    }
}
