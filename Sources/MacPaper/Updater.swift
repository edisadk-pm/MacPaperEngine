import AppKit
import Combine
import CryptoKit
import MacPaperCore

/// Keeps MacPaperEngine up to date from its GitHub Releases.
///
/// A release carries `MacPaperEngine.zip` and `MacPaperEngine.zip.sha256`. A newer one is
/// downloaded in the background, checked (checksum, bundle identifier, version, code signature)
/// and unpacked next to the library. It replaces the app when the window closes, or straight
/// away with Restart Now. Only this window process does any of it; the engine never goes online.
///
/// It looks each time the window opens. The first launch says so in a sheet and offers the
/// choices: install automatically, ask first, or only look when told to. After an update, the
/// sidebar says what's new.
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// Found, but automatic installs are off.
        case available(version: String)
        case downloading(version: String, progress: Double)
        case ready(version: String)
        case installing
        case failed(String)
    }

    /// How far the updater goes on its own.
    enum Mode: String, CaseIterable {
        /// Checks on opening, downloads, and installs when the window closes.
        case automatic
        /// Checks on opening, then waits for a click before downloading.
        case ask
        /// Only Check for Updates.
        case manual

        var title: String {
            switch self {
            case .automatic: "Install updates automatically"
            case .ask: "Ask before installing"
            case .manual: "Only when I check"
            }
        }

        var shortTitle: String {
            switch self {
            case .automatic: "Automatic"
            case .ask: "Ask First"
            case .manual: "Manual"
            }
        }

        var detail: String {
            switch self {
            case .automatic: "Checks when you open MacPaperEngine and installs when you close it."
            case .ask: "Checks when you open MacPaperEngine and asks before downloading."
            case .manual: "Looks only when you choose Check for Updates."
            }
        }
    }

    /// Shown in the sidebar after an update has been installed.
    struct WhatsNew: Equatable {
        let version: String
        let notes: String
    }

    private enum Key {
        static let mode = "updateMode"
        /// Before there were modes: a switch for installing automatically.
        static let legacyAutomatic = "autoUpdate"
        static let introSeen = "updateIntroSeen"
        static let lastChecked = "updateLastChecked"
        static let lastRunVersion = "lastRunVersion"
    }

    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let repository = "edisadk-pm/MacPaperEngine"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    private static let assetName = "MacPaperEngine.zip"

    @Published private(set) var phase = Phase.idle
    @Published private(set) var lastChecked: Date?
    @Published var mode: Mode {
        didSet { modeChanged(from: oldValue) }
    }
    /// The one-time sheet that says the app updates itself.
    @Published private(set) var showsIntro = false
    @Published private(set) var whatsNew: WhatsNew?
    /// Later, on the sidebar's card: that version isn't offered again until the next launch.
    @Published private(set) var snoozedVersion: String?

    weak var app: AppModel?
    let appURL: URL
    let version: String
    private let feed: URL
    private let managesEngine: Bool
    private let defaults: UserDefaults
    private var pending: Release?
    private var staged: URL?
    private var task: Task<Void, Never>?
    private var started = false

    /// The defaults are the running app. Tests point it at a copy and a local feed instead.
    init(appURL: URL = Bundle.main.bundleURL, version: String = Updater.currentVersion,
         feed: URL? = nil, managesEngine: Bool = true) {
        let environment = ProcessInfo.processInfo.environment
        self.appURL = appURL
        self.version = version
        self.managesEngine = managesEngine
        self.feed = feed ?? environment["MACPAPER_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest")!
        // A test library keeps its own update settings, so trying the updater out leaves the
        // installed app's alone.
        let defaults = environment["MACPAPER_HOME"] == nil ? UserDefaults.standard
            : UserDefaults(suiteName: "app.macpaper.MacPaper.development") ?? .standard
        self.defaults = defaults
        mode = defaults.string(forKey: Key.mode).flatMap(Mode.init(rawValue:))
            ?? (defaults.object(forKey: Key.legacyAutomatic) as? Bool == false ? .ask : .automatic)
        lastChecked = defaults.object(forKey: Key.lastChecked) as? Date
        noteLaunch()
    }

    /// Development builds, run from the build folder or against a test library, never update
    /// themselves, unless pointed at a test feed.
    var isAvailable: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["MACPAPER_UPDATE_FEED"] != nil { return true }
        if environment["MACPAPER_HOME"] != nil { return false }
        return appURL.deletingLastPathComponent().lastPathComponent == "Applications"
    }

    var readyVersion: String? {
        if case .ready(let version) = phase { return version }
        return nil
    }

    // MARK: - Launch

    /// Once the window is up: the first time, asks how to update; afterwards, checks unless
    /// set to Manual. The check waits for the first-time answer.
    func start() {
        guard isAvailable, !started else { return }
        started = true
        if defaults.bool(forKey: Key.introSeen) {
            checkOnOpening()
        } else {
            showsIntro = true
        }
    }

    /// Continue, or the sheet closed: the choice made in it stands.
    func finishIntro() {
        guard showsIntro else { return }
        defaults.set(true, forKey: Key.introSeen)
        showsIntro = false
        checkOnOpening()
    }

    /// A newer version than last time means an update was just installed.
    private func noteLaunch() {
        guard isAvailable else { return }
        let previous = defaults.string(forKey: Key.lastRunVersion)
        defaults.set(version, forKey: Key.lastRunVersion)
        guard let previous, Self.isNewer(version, than: previous) else { return }
        // The summary line of this version's section in the bundled changelog.
        let entry = Changelog.entry(for: version)
        let notes = entry?.summary ?? entry?.items.first ?? ""
        whatsNew = WhatsNew(version: version, notes: Self.plainText(notes))
    }

    /// Release notes are Markdown. The sidebar has room for a few lines of plain text.
    private static func plainText(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = (try? AttributedString(markdown: markdown, options: options)).map { String($0.characters) } ?? markdown
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func dismissWhatsNew() {
        whatsNew = nil
    }

    func snooze() {
        if case .available(let version) = phase { snoozedVersion = version }
    }

    func releasePage(for version: String) -> URL {
        URL(string: "https://github.com/\(Self.repository)/releases/tag/v\(version)") ?? Self.releasesPage
    }

    private func modeChanged(from old: Mode) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        // Picking in General counts as answering the first-launch question.
        defaults.set(true, forKey: Key.introSeen)
        if mode == .automatic, case .available = phase { downloadAvailable() }
        // Turning checks on looks straight away rather than at the next opening.
        if old == .manual, started, !showsIntro, phase == .idle { checkOnOpening() }
    }

    // MARK: - Checking

    private func checkOnOpening() {
        guard mode != .manual else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard isAvailable, task == nil else { return }
        if let ready = readyVersion {
            if userInitiated { app?.show(notice: "Version \(ready) is ready to install") }
            return
        }
        phase = .checking
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                let release = try await self.fetchLatest()
                self.lastChecked = Date()
                self.defaults.set(self.lastChecked, forKey: Key.lastChecked)
                guard Self.isNewer(release.version, than: self.version) else {
                    self.phase = .upToDate
                    if userInitiated { self.app?.show(notice: "MacPaperEngine \(self.version) is the latest version") }
                    return
                }
                self.pending = release
                if self.mode == .automatic || userInitiated {
                    try await self.download(release)
                } else {
                    self.phase = .available(version: release.version)
                    self.app?.show(notice: "MacPaperEngine \(release.version) is available")
                }
            } catch {
                self.phase = .failed(error.localizedDescription)
                if userInitiated { self.app?.alert = "Couldn't check for updates. \(error.localizedDescription)" }
            }
        }
    }

    /// Downloads the update found while automatic installs were off.
    func downloadAvailable() {
        guard let pending, task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                try await self.download(pending)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    struct Release {
        let version: String
        let archive: URL
        let checksum: URL
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let json = try await OnlineHTTP.json(request, provider: "GitHub") as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw UpdateError.unreadableRelease
        }
        let links = Dictionary(uniqueKeysWithValues: assets.compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (name, link)
        })
        guard let archive = links[Self.assetName], let checksum = links[Self.assetName + ".sha256"] else {
            throw UpdateError.unreadableRelease
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, archive: archive, checksum: checksum)
    }

    /// Compares dotted version numbers, so 1.10 is newer than 1.9.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        var a = parts(candidate), b = parts(current)
        let length = max(a.count, b.count)
        a += Array(repeating: 0, count: length - a.count)
        b += Array(repeating: 0, count: length - b.count)
        return a.lexicographicallyPrecedes(b) == false && a != b
    }

    // MARK: - Downloading and checking

    enum UpdateError: LocalizedError {
        case unreadableRelease, checksumMismatch, wrongApp, unsigned, unpackFailed

        var errorDescription: String? {
            switch self {
            case .unreadableRelease: "The latest release doesn't contain an app to install."
            case .checksumMismatch: "The download was damaged. It will be tried again later."
            case .wrongApp: "The download isn't the version of MacPaperEngine it should be."
            case .unsigned: "The downloaded app's signature isn't valid."
            case .unpackFailed: "The download couldn't be unpacked."
            }
        }
    }

    private var stagingFolder: URL { Paths.root.appendingPathComponent("Update", isDirectory: true) }

    private func download(_ release: Release) async throws {
        phase = .downloading(version: release.version, progress: 0)
        let archive = try await OnlineHTTP.download(release.archive) { [weak self] fraction in
            self?.phase = .downloading(version: release.version, progress: min(fraction, 0.99))
        }
        defer { try? FileManager.default.removeItem(at: archive) }

        let (checksumData, _) = try await OnlineHTTP.session.data(from: release.checksum)
        let expected = String(decoding: checksumData, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
        let folder = stagingFolder
        let appName = appURL.lastPathComponent
        let expectedIdentifier = Bundle(url: appURL)?.bundleIdentifier ?? IPC.appBundleID

        let unpacked: URL = try await Task.detached(priority: .utility) {
            guard let expected, try Self.sha256(of: archive) == expected else { throw UpdateError.checksumMismatch }
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]) else { throw UpdateError.unpackFailed }
            let app = folder.appendingPathComponent(appName)
            // Read from disk: Bundle caches by path, and the staging path is the same every time.
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
            guard info?["CFBundleIdentifier"] as? String == expectedIdentifier,
                  info?["CFBundleShortVersionString"] as? String == release.version else {
                throw UpdateError.wrongApp
            }
            guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else {
                throw UpdateError.unsigned
            }
            return app
        }.value

        staged = unpacked
        phase = .ready(version: release.version)
        app?.show(notice: "Version \(release.version) is ready. It installs when you close this window.")
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Installing

    /// Restart Now: installs, then opens the new version once this one has quit.
    func installNow() {
        guard install() else { return }
        let path = appURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        // A copy of this app is still running, so `open` would just bring it forward. A small
        // shell waits for it to exit first.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// When the window closes: installs a ready update and restarts the engine on it, so the
    /// wallpaper is back within a second or two and the next window is the new version. A ready
    /// update was either downloaded automatically or by a click, so either way it's wanted.
    func installOnQuit() {
        guard readyVersion != nil else { return }
        let engineWasRunning = isEngineRunning
        guard install(), managesEngine, engineWasRunning else { return }
        Self.run("/usr/bin/open", ["-g", appURL.appendingPathComponent(Paths.helperPath).path])
    }

    private var isEngineRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: IPC.engineBundleID).isEmpty
    }

    /// Swaps the app on disk for the staged one. The engine is stopped first so nothing runs
    /// from the old copy.
    private func install() -> Bool {
        guard let staged, FileManager.default.fileExists(atPath: staged.path) else { return false }
        phase = .installing
        if managesEngine, isEngineRunning {
            IPC.post(IPC.quitEngine)
            let deadline = Date().addingTimeInterval(4)
            while isEngineRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        do {
            _ = try FileManager.default.replaceItemAt(appURL, withItemAt: staged)
        } catch {
            // Replacing in one step needs both on the same volume. Otherwise: move aside, move in.
            let aside = appURL.deletingLastPathComponent().appendingPathComponent(".\(appURL.lastPathComponent).old")
            do {
                try? FileManager.default.removeItem(at: aside)
                try FileManager.default.moveItem(at: appURL, to: aside)
                try FileManager.default.moveItem(at: staged, to: appURL)
                try? FileManager.default.removeItem(at: aside)
            } catch {
                if !FileManager.default.fileExists(atPath: appURL.path) {
                    try? FileManager.default.moveItem(at: aside, to: appURL)
                }
                phase = .failed("The update couldn't be installed: \(error.localizedDescription)")
                return false
            }
        }
        self.staged = nil
        try? FileManager.default.removeItem(at: stagingFolder)
        return true
    }
}
