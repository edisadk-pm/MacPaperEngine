import AppKit
import MacPaperCore
import SwiftUI

@main
enum MacPaperMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: AppModel?
    private var menu: MainMenu?
    private var toolbar: MainToolbar?
    /// Files opened at launch can arrive before the model exists.
    private var pendingImports: [URL] = []

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.importFiles(urls)
        } else {
            pendingImports += urls
        }
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        Paths.prepare()
        // One window, so no tabs, and none of the tab commands macOS would add to the View menu.
        NSWindow.allowsAutomaticWindowTabbing = false

        let model = AppModel()
        self.model = model
        let menu = MainMenu(model: model)
        NSApp.mainMenu = menu.build()
        self.menu = menu
        model.ensureEngineRunning()
        model.importFiles(pendingImports)
        pendingImports = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Theme.windowWidth, height: Theme.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "MacPaperEngine"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        // A fixed width has no full-screen form.
        window.collectionBehavior.insert(.fullScreenNone)
        window.contentViewController = MainSplitViewController(model: model)

        let toolbar = MainToolbar(model: model, window: window)
        self.toolbar = toolbar
        menu.toolbar = toolbar

        // Setting the content controller sizes the window to it, so the real size comes last.
        window.setFrame(NSRect(x: 0, y: 0, width: Theme.windowWidth, height: Theme.windowHeight), display: false)
        window.minSize = window.frame.size
        window.maxSize = NSSize(width: window.frame.width, height: .greatestFiniteMagnitude)
        window.center()
        // Brings back the height and place the window had last time, if any, at the fixed width.
        window.setFrameAutosaveName("MacPaper")
        if window.frame.width != Theme.windowWidth {
            var frame = window.frame
            frame.size.width = Theme.windowWidth
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    /// A downloaded update replaces the app as it quits, and the wallpaper restarts on it.
    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        model?.updater.installOnQuit()
    }

    /// Closing the window ends this process. The engine keeps the wallpaper running on its own,
    /// so all of SwiftUI's memory goes back to the system.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
