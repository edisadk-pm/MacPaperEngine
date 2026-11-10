import AppKit
import MacPaperCore

/// The menu bar: the usual Mac menus, plus a Wallpaper menu for what's on the desktop. Standard
/// commands (copy, full screen, sidebar, window) go to the responder chain as in any Mac app.
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    private let model: AppModel
    var toolbar: MainToolbar?

    /// View menu order. The first nine are also ⌘1 to ⌘9.
    private static let pages: [Page] = [.videos, .dynamic, .pictures, .online, .displays, .playback, .power, .general, .stats, .about]

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(wallpaperMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
        return main
    }

    // MARK: - Menus

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "MacPaperEngine")
        menu.addItem(item("About MacPaperEngine", #selector(showAbout)))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(standard("Hide MacPaperEngine", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(standard("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]))
        menu.addItem(standard("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(standard("Quit MacPaperEngine", #selector(NSApplication.terminate(_:)), key: "q"))
        // Held Option: closing the window normally leaves the wallpaper running.
        let quitAll = item("Quit MacPaperEngine and Stop Wallpaper", #selector(quitAndStop), key: "q", modifiers: [.command, .option])
        quitAll.isAlternate = true
        menu.addItem(quitAll)
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Add Wallpapers…", #selector(addWallpapers), key: "o"))
        menu.addItem(item("Show Library in Finder", #selector(showLibrary)))
        menu.addItem(.separator())
        menu.addItem(standard("Close Window", #selector(NSWindow.performClose(_:)), key: "w"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(standard("Undo", Selector(("undo:")), key: "z"))
        menu.addItem(standard("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(standard("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(standard("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(standard("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(standard("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        menu.addItem(item("Search Online…", #selector(searchOnline), key: "f"))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Back", #selector(goBack), key: "["))
        menu.addItem(item("Forward", #selector(goForward), key: "]"))
        menu.addItem(.separator())
        for (position, page) in Self.pages.enumerated() {
            let entry = item(page.title, #selector(showPage(_:)), key: position < 9 ? String(position + 1) : "")
            entry.tag = position
            entry.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(standard("Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), key: "s", modifiers: [.command, .control]))
        menu.addItem(standard("Hide Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), key: "t", modifiers: [.command, .option]))
        return menu
    }

    private func wallpaperMenu() -> NSMenu {
        let menu = NSMenu(title: "Wallpaper")
        menu.addItem(item("Pause", #selector(togglePause), key: "p", modifiers: [.command, .option]))
        menu.addItem(item("Turn Wallpaper Off", #selector(toggleEnabled)))
        menu.addItem(.separator())
        menu.addItem(item("Next Wallpaper", #selector(nextWallpaper), key: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                          modifiers: [.command, .option]))
        menu.addItem(item("Previous Wallpaper", #selector(previousWallpaper), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                          modifiers: [.command, .option]))
        menu.addItem(item("Show Current Wallpaper", #selector(revealCurrent)))
        // No ⌘⌫: in the search field that keystroke means "delete to start of line".
        menu.addItem(item("Remove Current Wallpaper…", #selector(removeCurrent)))
        menu.addItem(.separator())
        menu.addItem(item("Same Wallpaper on All Displays", #selector(toggleSameOnAll)))
        menu.addItem(item("Play on Lock Screen", #selector(toggleLockScreen)))
        menu.addItem(item("Hide Loop Jump", #selector(toggleSmoothLoops)))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(standard("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(standard("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Get a Free Pexels Key", #selector(openPexelsKey)))
        menu.addItem(item("Find Dynamic Wallpapers Online", #selector(openDynamicClub)))
        menu.addItem(item("Visit Wallhaven", #selector(openWallhaven)))
        return menu
    }

    // MARK: - Building items

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// An item handled here.
    private func item(_ title: String, _ action: Selector, key: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    /// An item for whichever window, view or the app handles it.
    private func standard(_ title: String, _ action: Selector, key: String = "",
                          modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    // MARK: - State

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let settings = model.settings
        switch item.action {
        case #selector(goBack): return model.canGoBack
        case #selector(goForward): return model.canGoForward
        case #selector(showPage(_:)):
            item.state = Self.pages[item.tag] == model.page ? .on : .off
            return true
        case #selector(togglePause):
            item.title = model.isPausedByUser ? "Resume" : "Pause"
            return settings.enabled && (model.status.state == .playing || model.status.state == .paused)
        case #selector(toggleEnabled):
            item.title = settings.enabled ? "Turn Wallpaper Off" : "Turn Wallpaper On"
            return true
        case #selector(nextWallpaper), #selector(previousWallpaper):
            return settings.enabled
        case #selector(checkForUpdates):
            return model.updater.isAvailable
        case #selector(revealCurrent):
            return model.currentWallpaper != nil
        case #selector(removeCurrent):
            guard let current = model.currentWallpaper else {
                item.title = "Remove Current Wallpaper…"
                return false
            }
            if current.isBuiltIn {
                item.title = "Remove Download of “\(current.name)”…"
                return current.isDownloaded
            }
            item.title = "Remove “\(current.name)” from Library…"
            return true
        case #selector(toggleSameOnAll):
            item.state = settings.sameOnAllDisplays ? .on : .off
            return true
        case #selector(toggleLockScreen):
            item.state = settings.lockScreen ? .on : .off
            return true
        case #selector(toggleSmoothLoops):
            item.state = settings.smoothLoops ? .on : .off
            return true
        default:
            return true
        }
    }

    // MARK: - Actions

    @objc private func openSettings() { model.page = .general }
    @objc private func showAbout() { model.page = .about }

    @objc private func checkForUpdates() {
        model.page = .general
        model.updater.check(userInitiated: true)
    }
    @objc private func addWallpapers() { model.presentImportPanel(for: model.page.category) }
    @objc private func showLibrary() { NSWorkspace.shared.open(Paths.root) }
    @objc private func goBack() { model.goBack() }
    @objc private func goForward() { model.goForward() }
    @objc private func showPage(_ sender: NSMenuItem) { model.page = Self.pages[sender.tag] }
    @objc private func togglePause() { model.togglePause() }
    @objc private func nextWallpaper() { model.step(by: 1) }
    @objc private func previousWallpaper() { model.step(by: -1) }

    @objc private func searchOnline() {
        if let toolbar { toolbar.focusSearch() } else { model.page = .online }
    }

    @objc private func toggleEnabled() {
        let on = !model.settings.enabled
        model.mutate { $0.settings.enabled = on }
        if on { model.ensureEngineRunning() }
    }

    @objc private func revealCurrent() {
        if let current = model.currentWallpaper { model.page = Page(current.category) }
    }

    @objc private func removeCurrent() {
        guard let current = model.currentWallpaper else { return }
        if current.isBuiltIn { model.confirmRemoveDownload(current) } else { model.confirmRemove(current) }
    }

    @objc private func toggleSameOnAll() { model.mutate { $0.settings.sameOnAllDisplays.toggle() } }
    @objc private func toggleLockScreen() { model.mutate { $0.settings.lockScreen.toggle() } }
    @objc private func toggleSmoothLoops() { model.setSmoothLoops(!model.settings.smoothLoops) }

    @objc private func quitAndStop() {
        model.stopEngine()
        NSApp.terminate(nil)
    }

    @objc private func openPexelsKey() { NSWorkspace.shared.open(Pexels.keyPage) }
    @objc private func openDynamicClub() { NSWorkspace.shared.open(URL(string: "https://dynamicwallpaper.club")!) }
    @objc private func openWallhaven() { NSWorkspace.shared.open(URL(string: "https://wallhaven.cc")!) }
}
