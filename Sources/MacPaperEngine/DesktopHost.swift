import AppKit
import MacPaperCore

protocol WallpaperContent: AnyObject {
    var layer: CALayer { get }
    /// Called on the main queue once the first frame is on screen.
    var onReady: (() -> Void)? { get set }
    /// False for pictures, which never need pausing or covered-desktop checks.
    var isAnimated: Bool { get }
    func start()
    func stop()
    func setPaused(_ paused: Bool)
    func apply(settings: WallpaperSettings)
    func layout(in bounds: CGRect)
    func updateBacking(scale: CGFloat)
    /// Called every couple of seconds and after wake.
    func recoverIfNeeded()
}

extension WallpaperContent {
    func updateBacking(scale: CGFloat) {}
}

/// A borderless window glued to the desktop: below Finder's icons, above the system wallpaper.
final class DesktopWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Transparent until the first frame lands so the switch fades from the system wallpaper.
        isOpaque = false
        backgroundColor = .clear
    }

    func becomeOpaque() {
        backgroundColor = .black
        isOpaque = true
    }
}

final class DesktopHost {
    private let window = DesktopWindow()
    private var content: WallpaperContent?
    private var outgoing: WallpaperContent?
    private let rootView = NSView()

    private(set) var wallpaperID: String?
    /// The file being played, which changes when a smooth-loop copy becomes ready or is turned off.
    private var contentURL: URL?
    private(set) var isPaused = false
    var isAnimated: Bool { content?.isAnimated ?? false }
    private(set) var displayID: CGDirectDisplayID = 0

    private static let fadeDuration: CFTimeInterval = 0.5

    init() {
        rootView.wantsLayer = true
        window.contentView = rootView
    }

    func update(screen: NSScreen, wallpaper: Wallpaper, settings: WallpaperSettings) {
        displayID = screen.displayID
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: false)
        }
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        let url = wallpaper.kind == .video ? wallpaper.playbackURL(smoothLoops: settings.smoothLoops) : wallpaper.fileURL

        if wallpaper.id != wallpaperID || url != contentURL || content == nil {
            replaceContent(with: wallpaper, url: url, screen: screen, settings: settings, bounds: bounds)
        } else {
            content?.updateBacking(scale: screen.backingScaleFactor)
            content?.apply(settings: settings)
            content?.layout(in: bounds)
        }
        window.orderFront(nil)
    }

    private func replaceContent(with wallpaper: Wallpaper, url: URL?, screen: NSScreen,
                                settings: WallpaperSettings, bounds: CGRect) {
        // A fast double-switch: drop the one that was already on its way out.
        finishOutgoing()

        let next: WallpaperContent?
        switch wallpaper.kind {
        case .video:
            next = url.map { VideoContent(url: $0, settings: settings) }
        case .image, .dynamic:
            next = url.map {
                StillContent(url: $0, dynamic: wallpaper.kind == .dynamic, bounds: bounds,
                             scale: screen.backingScaleFactor, settings: settings)
            }
        }
        guard let next, let rootLayer = rootView.layer else { return }

        outgoing = content
        content = next
        wallpaperID = wallpaper.id
        contentURL = url

        next.layer.opacity = 0
        next.layout(in: bounds)
        rootLayer.addSublayer(next.layer)
        next.onReady = { [weak self, weak next] in
            guard let self, let next, self.content === next else { return }
            self.fadeIn(next)
        }
        next.start()
        next.setPaused(isPaused)
    }

    private func fadeIn(_ next: WallpaperContent) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeDuration)
        CATransaction.setCompletionBlock { [weak self] in
            self?.finishOutgoing()
            self?.window.becomeOpaque()
        }
        next.layer.opacity = 1
        CATransaction.commit()
    }

    private func finishOutgoing() {
        outgoing?.stop()
        outgoing?.layer.removeFromSuperlayer()
        outgoing = nil
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        content?.setPaused(paused)
    }

    func recoverIfNeeded() {
        content?.recoverIfNeeded()
    }

    func close() {
        finishOutgoing()
        content?.stop()
        content?.layer.removeFromSuperlayer()
        content = nil
        wallpaperID = nil
        contentURL = nil
        window.orderOut(nil)
        window.contentView = nil
    }
}
