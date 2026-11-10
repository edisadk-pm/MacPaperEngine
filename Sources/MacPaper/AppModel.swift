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
    /// Built-ins being downloaded, by wallpaper, from 0 to 1.
    @Published private(set) var fetching: [String: Double] = [:]
    @Published private(set) var includedBytes: Int64 = 0
    private var fetchTasks: [String: Task<Void, Never>] = [:]
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
    private(set) lazy var updater: Updater = {
        let updater = Updater()
        updater.app = self
        return updater
    }()
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
        fetchWallpapersInUse()
        restoreLoginItem()
        // Left a moment so the window is up before any network traffic.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.updater.checkIfDue() }
    }

    // MARK: - Engine

    private var engineApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: IPC.engineBundleID).first
    }

    var isEngineRunning: Bool { engineApp != nil }

    private var engineURL: URL {
        Bundle.main.bundleURL.appendingPathComponent(Paths.helperPath)
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
        refreshIncludedBytes()
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
        // A download announces itself when it lands.
        if list[next].isDownloaded { show(notice: "Now showing “\(list[next].name)”") }
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
        // A built-in not here yet is downloaded first, and applied once it arrives.
        if wallpaper.needsDownload {
            fetch(wallpaper, apply: true)
            return
        }
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

    // MARK: - Built-ins, downloaded on first use

    func fetch(_ wallpaper: Wallpaper, apply: Bool) {
        guard wallpaper.needsDownload, fetchTasks[wallpaper.id] == nil,
              let remote = wallpaper.remoteURL, let local = wallpaper.fileURL else { return }
        fetching[wallpaper.id] = 0
        fetchTasks[wallpaper.id] = Task { [weak self] in
            defer {
                self?.fetchTasks[wallpaper.id] = nil
                self?.fetching[wallpaper.id] = nil
            }
            do {
                let file = try await OnlineHTTP.download(remote) { fraction in
                    self?.fetching[wallpaper.id] = min(fraction, 0.99)
                }
                // A cut-off download would otherwise sit there looking like the real file.
                let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
                if let expected = wallpaper.downloadSize, size != expected {
                    try? FileManager.default.removeItem(at: file)
                    throw OnlineError.unreadable(provider: "The download")
                }
                Paths.prepare()
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: file, to: local)
                guard let self else { return }
                self.refreshIncludedBytes()
                if apply {
                    self.apply(wallpaper)
                    self.show(notice: "Now showing “\(wallpaper.name)”")
                } else {
                    // The engine may be waiting for this file because it's already selected.
                    IPC.post(IPC.settingsChanged)
                    self.show(notice: "Downloaded “\(wallpaper.name)”")
                }
            } catch is CancellationError {
            } catch {
                self?.alert = "“\(wallpaper.name)” couldn't be downloaded. \(error.localizedDescription)"
            }
        }
    }

    func cancelFetch(_ wallpaper: Wallpaper) {
        fetchTasks[wallpaper.id]?.cancel()
    }

    /// A wallpaper already selected but not on this Mac (after an update, say) is fetched now,
    /// and shows up on the desktop as soon as it arrives.
    private func fetchWallpapersInUse() {
        let selected = Set([settings.sharedWallpaper].compactMap { $0 } + settings.perDisplay.values)
        for id in selected {
            if let wallpaper = state.wallpaper(id: id), wallpaper.needsDownload {
                fetch(wallpaper, apply: false)
            }
        }
    }

    /// Removing a download costs only a re-download, so it only asks when the wallpaper is on
    /// screen and the desktop would change.
    func confirmRemoveDownload(_ wallpaper: Wallpaper) {
        guard wallpaper.isBuiltIn, wallpaper.isDownloaded else { return }
        guard isOnScreen(wallpaper) else {
            removeDownload(wallpaper)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove the download of “\(wallpaper.name)”?"
        let frees = wallpaper.downloadSize.map { "It frees \(Format.storage(Int64($0))), and" } ?? "It"
        alert.informativeText = "It's on your desktop now, so the desktop goes back to your system wallpaper. \(frees) downloads again when you pick it."
        let removeButton = alert.addButton(withTitle: "Remove Download")
        removeButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let finish = { [weak self] (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { self?.removeDownload(wallpaper) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// Frees the space a downloaded built-in takes. It can be downloaded again any time.
    func removeDownload(_ wallpaper: Wallpaper) {
        guard wallpaper.isBuiltIn, let local = wallpaper.fileURL, wallpaper.isDownloaded else { return }
        if isOnScreen(wallpaper) {
            mutate { state in
                if state.settings.sharedWallpaper == wallpaper.id { state.settings.sharedWallpaper = nil }
                state.settings.perDisplay = state.settings.perDisplay.filter { $0.value != wallpaper.id }
            }
        }
        try? FileManager.default.removeItem(at: local)
        refreshIncludedBytes()
        show(notice: "Removed the download of “\(wallpaper.name)”")
    }

    /// Removes every downloaded built-in that isn't on screen.
    func removeUnusedDownloads() {
        for wallpaper in FootageCatalog.all + IncludedDynamicCatalog.all
        where wallpaper.isDownloaded && !isOnScreen(wallpaper) {
            if let local = wallpaper.fileURL { try? FileManager.default.removeItem(at: local) }
        }
        refreshIncludedBytes()
        show(notice: "Removed downloads not in use")
    }

    func refreshIncludedBytes() {
        includedBytes = (FootageCatalog.all + IncludedDynamicCatalog.all).reduce(0) { total, wallpaper in
            guard wallpaper.isDownloaded, let url = wallpaper.fileURL,
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return total }
            return total + size.int64Value
        }
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
            details.append("MacPaperEngine's copy is deleted. The file you added from your Mac isn't touched.")
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
    func isOnScreen(_ wallpaper: Wallpaper) -> Bool {
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

    private static let startAtLoginKey = "startAtLogin"

    /// The login item is registered by path, so moving or renaming the app breaks it. Whether
    /// it should start at login is remembered, and the registration redone when it went missing.
    private func restoreLoginItem() {
        let defaults = UserDefaults.standard
        switch loginService.status {
        case .enabled:
            defaults.set(true, forKey: Self.startAtLoginKey)
        case .notRegistered, .notFound:
            guard defaults.bool(forKey: Self.startAtLoginKey) else { return }
            try? loginService.register()
        default:
            // Waiting for approval in System Settings, which is the user's call.
            break
        }
    }

    func setOpensAtLogin(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.startAtLoginKey)
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
