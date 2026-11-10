import AppKit
import Combine
import MacPaperCore
import SwiftUI

/// A sidebar and a detail pane, the way System Settings and Finder are built, so the sidebar
/// can be collapsed and resized and the toolbar lines up with the pane below it.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)

        let sidebar = NSHostingController(rootView: SidebarView(model: model))
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // The window has a fixed width, so the sidebar does too. It can still be hidden.
        sidebarItem.minimumThickness = Theme.sidebarWidth
        sidebarItem.maximumThickness = Theme.sidebarWidth
        sidebarItem.canCollapse = true

        let detailItem = NSSplitViewItem(viewController: DetailViewController(model: model))
        detailItem.minimumThickness = 520

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
        splitView.autosaveName = "MacPaperSplit"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The page area: a blurred, tinted backdrop with the SwiftUI page on top.
@MainActor
final class DetailViewController: NSViewController {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active

        let host = NSHostingView(rootView: DetailView(model: model))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        view = blur
    }
}

/// The window's toolbar: sidebar button, Back and Forward, the page's title, then whatever the
/// page needs (Add on library tabs, the source switch and search on Online) and Pause.
@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    private enum ID {
        static let back = NSToolbarItem.Identifier("back")
        static let forward = NSToolbarItem.Identifier("forward")
        static let add = NSToolbarItem.Identifier("add")
        static let kind = NSToolbarItem.Identifier("onlineKind")
        static let search = NSToolbarItem.Identifier("search")
        static let pause = NSToolbarItem.Identifier("pause")
    }

    private let toolbar = NSToolbar(identifier: "MacPaperMain")
    private let model: AppModel
    private weak var window: NSWindow?
    private var observers = Set<AnyCancellable>()

    private weak var backItem: NSToolbarItem?
    private weak var forwardItem: NSToolbarItem?
    private weak var addItem: NSToolbarItem?
    private weak var pauseItem: NSToolbarItem?
    private weak var kindItem: NSToolbarItemGroup?
    private weak var searchItem: NSSearchToolbarItem?

    private static let leading: [NSToolbarItem.Identifier] = [
        .toggleSidebar, .sidebarTrackingSeparator, ID.back, ID.forward, .flexibleSpace,
    ]

    init(model: AppModel, window: NSWindow) {
        self.model = model
        self.window = window
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // The items change with the page, which doesn't mix with rearranging them by hand.
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        model.$page.sink { [weak self] page in
            DispatchQueue.main.async { self?.pageChanged(page) }
        }.store(in: &observers)
        model.$backStack.combineLatest(model.$forwardStack).sink { [weak self] back, forward in
            self?.backItem?.isEnabled = !back.isEmpty
            self?.forwardItem?.isEnabled = !forward.isEmpty
        }.store(in: &observers)
        model.$status.sink { [weak self] status in
            DispatchQueue.main.async { self?.updatePause(status) }
        }.store(in: &observers)
        model.$state.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &observers)
        model.online.$kind.sink { [weak self] kind in
            DispatchQueue.main.async { self?.kindChanged(kind) }
        }.store(in: &observers)
        model.online.$query.sink { [weak self] query in
            guard let field = self?.searchItem?.searchField, field.stringValue != query else { return }
            field.stringValue = query
        }.store(in: &observers)
        model.$pexelsKey.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSearchAvailability() }
        }.store(in: &observers)
    }

    /// Puts the cursor in the Online search field, opening Online first.
    func focusSearch() {
        model.page = .online
        DispatchQueue.main.async { [weak self] in self?.searchItem?.beginSearchInteraction() }
    }

    // MARK: - Keeping the items in step with the page

    private func trailing(for page: Page) -> [NSToolbarItem.Identifier] {
        switch page {
        case .videos, .dynamic, .pictures: [ID.add, ID.pause]
        case .online: [ID.kind, ID.search, ID.pause]
        default: [ID.pause]
        }
    }

    private func pageChanged(_ page: Page) {
        let wanted = Self.leading + trailing(for: page)
        let current = toolbar.items.map(\.itemIdentifier)
        if wanted != current {
            var shared = 0
            while shared < min(wanted.count, current.count), wanted[shared] == current[shared] { shared += 1 }
            for index in stride(from: current.count - 1, through: shared, by: -1) { toolbar.removeItem(at: index) }
            for index in shared..<wanted.count { toolbar.insertItem(withItemIdentifier: wanted[index], at: index) }
        }
        addItem?.toolTip = page.category.map { "Add \(AppModel.title(for: $0).lowercased()) (⌘O)" }
        updateTitle()
    }

    private func updateTitle() {
        guard let window else { return }
        let page = model.page
        window.title = page.title
        window.subtitle = switch page {
        case .videos, .dynamic, .pictures:
            page.category.map { model.count($0) }.map { $0 == 1 ? "1 wallpaper" : "\($0) wallpapers" } ?? ""
        case .online:
            model.online.kind == .pictures ? "Pictures from Wallhaven" : "Videos from Pexels"
        default:
            ""
        }
    }

    private func updatePause(_ status: EngineStatus) {
        guard let item = pauseItem else { return }
        let paused = status.pausedByUser == true
        item.label = paused ? "Resume" : "Pause"
        item.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: item.label)
        item.toolTip = paused ? "Resume the wallpaper (⌥⌘P)" : "Pause the wallpaper (⌥⌘P)"
        // Pictures never play, so there's nothing to pause.
        item.isEnabled = model.settings.enabled && (status.state == .playing || status.state == .paused)
    }

    private func kindChanged(_ kind: OnlineModel.Kind) {
        kindItem?.selectedIndex = kind == .pictures ? 0 : 1
        searchItem?.searchField.placeholderString = kind == .pictures ? "Search Wallhaven" : "Search Pexels"
        updateSearchAvailability()
        updateTitle()
    }

    private func updateSearchAvailability() {
        searchItem?.searchField.isEnabled = !model.online.needsKey
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.leading + trailing(for: model.page)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.leading + [ID.add, ID.kind, ID.search, ID.pause]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ID.back:
            let item = button(identifier, label: "Back", symbol: "chevron.backward", tip: "See the previous page (⌘[)",
                              action: #selector(goBack))
            item.isNavigational = true
            item.isEnabled = model.canGoBack
            backItem = item
            return item
        case ID.forward:
            let item = button(identifier, label: "Forward", symbol: "chevron.forward", tip: "See the next page (⌘])",
                              action: #selector(goForward))
            item.isNavigational = true
            item.isEnabled = model.canGoForward
            forwardItem = item
            return item
        case ID.add:
            let item = button(identifier, label: "Add", symbol: "plus", tip: "Add wallpapers (⌘O)", action: #selector(add))
            addItem = item
            return item
        case ID.pause:
            let item = button(identifier, label: "Pause", symbol: "pause.fill", tip: "Pause the wallpaper",
                              action: #selector(togglePause))
            pauseItem = item
            updatePause(model.status)
            return item
        case ID.kind:
            let group = NSToolbarItemGroup(itemIdentifier: identifier, titles: ["Pictures", "Videos"],
                                           selectionMode: .selectOne, labels: ["Pictures", "Videos"],
                                           target: self, action: #selector(kindPicked))
            group.label = "Source"
            group.selectedIndex = model.online.kind == .pictures ? 0 : 1
            kindItem = group
            return group
        case ID.search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "Search"
            item.preferredWidthForSearchField = 220
            item.resignsFirstResponderWithCancel = true
            let field = item.searchField
            field.delegate = self
            field.target = self
            field.action = #selector(searchSubmitted)
            field.sendsWholeSearchString = true
            field.stringValue = model.online.query
            field.placeholderString = model.online.kind == .pictures ? "Search Wallhaven" : "Search Pexels"
            searchItem = item
            updateSearchAvailability()
            return item
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, label: String, symbol: String, tip: String,
                        action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.autovalidates = false
        item.target = self
        item.action = action
        return item
    }

    // MARK: - Actions

    @objc private func goBack() { model.goBack() }
    @objc private func goForward() { model.goForward() }
    @objc private func add() { model.presentImportPanel(for: model.page.category) }
    @objc private func togglePause() { model.togglePause() }

    @objc private func kindPicked() {
        guard let group = kindItem else { return }
        model.online.kind = group.selectedIndex == 1 ? .videos : .pictures
    }

    @objc private func searchSubmitted() {
        model.online.search(searchItem?.searchField.stringValue ?? "")
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        model.online.query = field.stringValue
        model.online.queryChanged()
    }
}
