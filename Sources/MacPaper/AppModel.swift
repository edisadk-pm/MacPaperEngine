import AppKit
import Combine
import MacPaperCore
import ServiceManagement
import UniformTypeIdentifiers

enum Page: String, CaseIterable, Identifiable {
    case videos, dynamic, pictures, online, displays, playback, power, general, stats
    var id: String { rawValue }

    init(_ category: Wallpaper.Category) {
        switch category {
        case .videos: self = .videos
        case .dynamic: self = .dynamic
        case .pictures: self = .pictures
        }
    }

    var category: Wallpaper.Category? {
        switch self {
        case .videos: .videos
        case .dynamic: .dynamic
        case .pictures: .pictures
        default: nil
        }
    }

    /// Pages saved by older versions.
    static func restored(_ raw: String?) -> Page {
        switch raw {
        case "about": .general
        case let raw?: Page(rawValue: raw) ?? .videos
        case nil: .videos
        }
    }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let pixels: String
    let isMain: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = Store.loadState()
    @Published private(set) var stats = Store.loadStats()
    @Published private(set) var status = EngineStatus(state: .idle, detail: "Starting")
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var lockRecord = Store.loadLockScreen()
    @Published private(set) var engineFootprint: UInt64?
    @Published private(set) var decoderFootprint: UInt64?
    @Published private(set) var windowFootprint: UInt64?
    @Published private(set) var importing = 0
    /// Smooth-loop copies being made, by wallpaper, from 0 to 1.
    @Published private(set) var smoothing: [String: Double] = [:]
    @Published private(set) var libraryBytes: Int64 = 0
    @Published var page = Page.restored(UserDefaults.standard.string(forKey: "page")) {
        didSet {
            UserDefaults.standard.set(page.rawValue, forKey: "page")
            guard page != oldValue else { return }
            if movingThroughHistory {
                movingThroughHistory = false
            } else {
                backStack.append(oldValue)
                forwardStack.removeAll()
            }
        }
    }
    /// Pages visited, for Back and Forward.
    @Published private(set) var backStack: [Page] = []
    @Published private(set) var forwardStack: [Page] = []
    private var movingThroughHistory = false
    /// Which display the Library assigns to when displays have separate wallpapers.
    @Published var targetDisplay: String?
    @Published var alert: String?
    /// A short confirmation shown at the bottom of the window.
    @Published private(set) var notice: String?
    @Published var pexelsKey = UserDefaults.standard.string(forKey: "pexelsKey") ?? "" {
        didSet { UserDefaults.standard.set(pexelsKey, forKey: "pexelsKey") }
    }

    var settings: WallpaperSettings { state.settings }

    private(set) lazy var online = OnlineModel(app: self)
    private var noticeTask: Task<Void, Never>?
    private var smoothingTask: Task<Void, Never>?

    private var observers: [NSObjectProtocol] = []

    init() {
        refreshDisplays()
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: IPC.statusChanged, object: nil, queue: .main) { [weak self] note in
            let status = IPC.decodeStatus(note.object as? String)
            Task { @MainActor in
                if let status { self?.status = status }
                self?.lockRecord = Store.loadLockScreen()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        })
        IPC.post(IPC.statusRequested)
        smoothLoopsIfNeeded()
    }

    // MARK: - Engine

    private var engineApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: IPC.engineBundleID).first
    }

    var isEngineRunning: Bool { engineApp != nil }

    private var engineURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/MacPaperEngine.app")
    }

    func ensureEngineRunning() {
        guard !isEngineRunning else {
            IPC.post(IPC.statusRequested)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        if let home = ProcessInfo.processInfo.environment["MACPAPER_HOME"] {
            configuration.environment = ["MACPAPER_HOME": home]
        }
        NSWorkspace.shared.openApplication(at: engineURL, configuration: configuration) { _, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.alert = "The engine couldn't start: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopEngine() {
        IPC.post(IPC.quitEngine)
        status = EngineStatus(state: .off, detail: "Engine stopped")
    }

    func refreshMeasurements() {
        engineFootprint = engineApp.flatMap { ProcessMemory.footprint(pid: $0.processIdentifier) }
        decoderFootprint = engineApp.map { ProcessMemory.decoderFootprint(for: $0.processIdentifier) }
        windowFootprint = ProcessMemory.footprint(pid: ProcessInfo.processInfo.processIdentifier)
        stats = Store.loadStats()
        libraryBytes = state.library.reduce(0) { total, wallpaper in
            total + [wallpaper.fileURL, wallpaper.smoothLoopURL].compactMap { $0 }.reduce(0) { sum, url in
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
                return sum + (size?.int64Value ?? 0)
            }
        }
    }

    func refreshDisplays() {
        displays = NSScreen.screens.enumerated().map { index, screen in
            let scale = screen.backingScaleFactor
            let width = Int(screen.frame.width * scale)
            let height = Int(screen.frame.height * scale)
            return DisplayInfo(id: screen.displayUUID, name: screen.localizedName,
                               pixels: "\(width) × \(height)", isMain: index == 0)
        }
        if let target = targetDisplay, !displays.contains(where: { $0.id == target }) {
            targetDisplay = nil
        }
    }

    // MARK: - Navigation

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(page)
        movingThroughHistory = true
        page = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(page)
        movingThroughHistory = true
        page = next
    }

    /// The wallpapers of one tab, in the order they're shown.
    func wallpapers(in category: Wallpaper.Category) -> [Wallpaper] {
        switch category {
        case .videos: FootageCatalog.all + userVideos
        case .dynamic: allDynamic
        case .pictures: userPictures
        }
    }

    /// Moves to the next or previous wallpaper in the current one's tab, wrapping around.
    func step(by offset: Int) {
        let category = currentWallpaper?.category ?? page.category ?? .videos
        let list = wallpapers(in: category)
        guard !list.isEmpty else { return }
        let position = currentWallpaper.flatMap { current in list.firstIndex { $0.id == current.id } }
        let next = position.map { ($0 + offset + list.count) % list.count } ?? (offset > 0 ? 0 : list.count - 1)
        apply(list[next])
        show(notice: "Now showing “\(list[next].name)”")
    }

    var isPausedByUser: Bool { status.pausedByUser == true }

    func togglePause() {
        ensureEngineRunning()
        IPC.post(IPC.togglePause)
    }

    // MARK: - What's in each tab

    var userVideos: [Wallpaper] { state.library.filter { $0.kind == .video } }
    var userPictures: [Wallpaper] { state.library.filter { $0.kind == .image } }
    var userDynamic: [Wallpaper] { state.library.filter { $0.kind == .dynamic } }
    /// Every dynamic wallpaper: MacPaper's own, then the user's.
    var allDynamic: [Wallpaper] { IncludedDynamicCatalog.all + userDynamic }

    func count(_ category: Wallpaper.Category) -> Int {
        switch category {
        case .videos: FootageCatalog.all.count + userVideos.count
        case .dynamic: allDynamic.count
        case .pictures: userPictures.count
        }
    }

    /// What the display being edited shows, or the main display's when they all match.
    var currentWallpaper: Wallpaper? {
        state.wallpaper(forDisplay: assignmentTarget ?? displays.first?.id)
    }

    func libraryItem(for source: Wallpaper.Source.Provider, remoteID: String) -> Wallpaper? {
        state.library.first { $0.source?.provider == source && $0.source?.remoteID == remoteID }
    }

    func show(notice text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Mutating state

    func mutate(_ change: (inout AppState) -> Void) {
        change(&state)
        Store.save(state)
        IPC.post(IPC.settingsChanged)
    }

    var showsDisplayPicker: Bool { !settings.sameOnAllDisplays && displays.count > 1 }

    var assignmentTarget: String? {
        guard showsDisplayPicker else { return nil }
        return targetDisplay ?? displays.first?.id
    }

    func isActive(_ wallpaper: Wallpaper) -> Bool {
        state.wallpaperID(forDisplay: assignmentTarget) == wallpaper.id
    }

    func toggle(_ wallpaper: Wallpaper) {
        let turnOff = isActive(wallpaper)
        mutate { state in
            if let target = assignmentTarget {
                state.settings.perDisplay[target] = turnOff ? nil : wallpaper.id
            } else {
                state.settings.sharedWallpaper = turnOff ? nil : wallpaper.id
                if state.settings.sameOnAllDisplays { state.settings.perDisplay = [:] }
            }
        }
        ensureEngineRunning()
    }

    func apply(_ wallpaper: Wallpaper) {
        if !isActive(wallpaper) { toggle(wallpaper) }
    }

    /// Asks before removing, since the library's copy of the file is deleted. The question can
    /// be turned off with its "Don't ask again" box.
    func confirmRemove(_ wallpaper: Wallpaper) {
        guard wallpaper.isRemovable else { return }
        let skipKey = "skipRemoveConfirmation"
        guard !UserDefaults.standard.bool(forKey: skipKey) else {
            remove(wallpaper)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(wallpaper.name)” from your library?"
        var details: [String] = []
        if let source = wallpaper.source {
            details.append("You can download it again from \(source.provider.name) in Online.")
        } else {
            details.append("MacPaper's copy is deleted. The file you added from your Mac isn't touched.")
        }
        if isOnScreen(wallpaper) {
            details.append("It's on your desktop now, so the desktop goes back to your system wallpaper.")
        }
        alert.informativeText = details.joined(separator: " ")
        let removeButton = alert.addButton(withTitle: "Remove")
        removeButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: skipKey) }
            self?.remove(wallpaper)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// On any display, not just the one being edited.
    private func isOnScreen(_ wallpaper: Wallpaper) -> Bool {
        settings.sharedWallpaper == wallpaper.id || settings.perDisplay.values.contains(wallpaper.id)
    }

    func remove(_ wallpaper: Wallpaper) {
        guard wallpaper.isRemovable else { return }
        mutate { state in
            state.library.removeAll { $0.id == wallpaper.id }
            if state.settings.sharedWallpaper == wallpaper.id { state.settings.sharedWallpaper = nil }
            state.settings.perDisplay = state.settings.perDisplay.filter { $0.value != wallpaper.id }
        }
        // The engine has already been told to let go of the file by the save above.
        if let url = wallpaper.fileURL { try? FileManager.default.removeItem(at: url) }
        if let url = wallpaper.smoothLoopURL { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: wallpaper.thumbnailURL)
        // A dynamic wallpaper also has one small picture per frame, for the Dynamic tab's timeline.
        let frames = (try? FileManager.default.contentsOfDirectory(atPath: Paths.thumbnails.path)) ?? []
        for name in frames where name.hasPrefix("\(wallpaper.id).frame") {
            try? FileManager.default.removeItem(at: Paths.thumbnails.appendingPathComponent(name))
        }
        show(notice: "Removed “\(wallpaper.name)”")
    }

    // MARK: - Importing

    /// Without a category, any kind of wallpaper can be chosen and each goes to its own tab.
    func presentImportPanel(for category: Wallpaper.Category?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = category.map(Importer.types(for:)) ?? Importer.acceptedTypes
        panel.message = switch category {
        case .videos?: "Choose videos, GIFs or other animated images"
        case .dynamic?: "Choose dynamic wallpapers (.heic) that change through the day"
        case .pictures?: "Choose pictures"
        case nil: "Choose videos, GIFs, pictures or dynamic wallpapers"
        }
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Adds files to the library. A single file is applied right away. Files that belong in
    /// another tab than the one showing say so, and that tab opens.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        importing += urls.count
        let applyWhenDone = urls.count == 1
        Task {
            var failures: [String] = []
            var added: [Wallpaper] = []
            for url in urls {
                do {
                    let wallpaper = try await Importer.importFile(url)
                    mutate { $0.library.append(wallpaper) }
                    added.append(wallpaper)
                    if applyWhenDone { apply(wallpaper) }
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                importing -= 1
            }
            if !failures.isEmpty { alert = failures.joined(separator: "\n") }
            reveal(added)
            smoothLoopsIfNeeded()
        }
    }

    // MARK: - Smooth loops

    func setSmoothLoops(_ on: Bool) {
        mutate { $0.settings.smoothLoops = on }
        if on { smoothLoopsIfNeeded() }
    }

    /// Makes the missing smooth-loop copies one at a time, the wallpaper on screen first. Each
    /// one tells the engine, which switches to it straight away.
    func smoothLoopsIfNeeded() {
        guard settings.smoothLoops, smoothingTask == nil else { return }
        smoothingTask = Task { [weak self] in
            while let self, self.settings.smoothLoops, !Task.isCancelled {
                let current = self.currentWallpaper?.id
                let pending = self.state.library
                    .filter { LoopSmoother.isNeeded(for: $0) }
                    .sorted { ($0.id == current ? 0 : 1) < ($1.id == current ? 0 : 1) }
                guard let next = pending.first else { break }
                self.smoothing[next.id] = 0
                do {
                    try await LoopSmoother.make(for: next) { fraction in
                        Task { @MainActor [weak self] in
                            if self?.smoothing[next.id] != nil { self?.smoothing[next.id] = fraction }
                        }
                    }
                    IPC.post(IPC.settingsChanged)
                } catch {
                    // Leaves the original to loop as before. Marking it stops endless retries.
                    if let url = next.smoothLoopURL {
                        try? FileManager.default.copyItem(at: next.fileURL!, to: url)
                    }
                }
                self.smoothing[next.id] = nil
            }
            self?.smoothingTask = nil
        }
    }

    private func reveal(_ added: [Wallpaper]) {
        guard let last = added.last else { return }
        let destination = Page(last.category)
        let title = Self.title(for: last.category)
        if added.count == 1 {
            show(notice: page == destination ? "Added “\(last.name)”" : "Added “\(last.name)” to \(title)")
        } else {
            show(notice: "Added \(added.count) wallpapers")
        }
        // Online keeps its place: downloads land there and say so in the tile.
        if page != .online { page = destination }
    }

    static func title(for category: Wallpaper.Category) -> String {
        switch category {
        case .videos: "Videos"
        case .dynamic: "Dynamic"
        case .pictures: "Pictures"
        }
    }

    // MARK: - Lock screen

    var lockScreenSummary: String {
        guard settings.lockScreen else {
            return "Replaces your system wallpaper until you turn this off"
        }
        if lockRecord.preparing { return "Preparing your wallpaper…" }
        if let error = lockRecord.error { return error }
        return lockRecord.name.map { "Showing “\($0)” when locked" } ?? "Choose a wallpaper first"
    }

    // MARK: - Login item

    private var loginService: SMAppService { SMAppService.loginItem(identifier: IPC.engineBundleID) }

    var opensAtLogin: Bool { loginService.status == .enabled }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try loginService.register()
            } else {
                try loginService.unregister()
            }
        } catch {
            alert = "Couldn't change the login item: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}
