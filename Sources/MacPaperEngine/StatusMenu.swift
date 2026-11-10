import AppKit
import MacPaperCore

final class StatusMenu: NSObject {
    private unowned let controller: EngineController
    private var item: NSStatusItem?
    private var status = EngineStatus(state: .idle, detail: "Starting")

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")

    init(controller: EngineController) {
        self.controller = controller
        super.init()
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            created.button?.image = Self.icon
            created.menu = makeMenu()
            item = created
            refresh()
        } else if !visible, let existing = item {
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    func update(status: EngineStatus) {
        self.status = status
        refresh()
    }

    private func refresh() {
        statusLine.title = status.detail
        pauseItem.title = controller.isPausedByUser ? "Resume" : "Pause"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        pauseItem.target = self
        menu.addItem(pauseItem)

        let open = NSMenuItem(title: "Open MacPaperEngine…", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Stop Wallpaper", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func togglePause() {
        controller.togglePausedByUser()
        refresh()
    }

    @objc private func openApp() {
        // …/MacPaper.app/Contents/Library/LoginItems/MacPaperEngine.app
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Hand-drawn so the engine doesn't pull in the SF Symbols font for one 18pt glyph.
    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 3.5, width: 14, height: 11),
                                     xRadius: 3, yRadius: 3)
            frame.lineWidth = 1.4
            frame.stroke()

            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: 4.8, y: 8.2))
            wave.curve(to: NSPoint(x: 9, y: 9), controlPoint1: NSPoint(x: 6, y: 11.4), controlPoint2: NSPoint(x: 7.6, y: 11))
            wave.curve(to: NSPoint(x: 13.2, y: 9.8), controlPoint1: NSPoint(x: 10.4, y: 7), controlPoint2: NSPoint(x: 12, y: 6.6))
            wave.lineWidth = 1.4
            wave.lineCapStyle = .round
            wave.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
