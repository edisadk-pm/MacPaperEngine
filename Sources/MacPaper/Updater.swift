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

    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let repository = "edisadk-pm/MacPaperEngine"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!
    private static let assetName = "MacPaperEngine.zip"
    private static let checkInterval: TimeInterval = 6 * 3600

    @Published private(set) var phase = Phase.idle
    @Published private(set) var lastChecked = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date
    @Published var installsAutomatically = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(installsAutomatically, forKey: "autoUpdate") }
    }

    weak var app: AppModel?
    let appURL: URL
    let version: String
    private let feed: URL
    private let managesEngine: Bool
    private var pending: Release?
    private var staged: URL?
    private var task: Task<Void, Never>?

    /// The defaults are the running app. Tests point it at a copy and a local feed instead.
    init(appURL: URL = Bundle.main.bundleURL, version: String = Updater.currentVersion,
         feed: URL? = nil, managesEngine: Bool = true) {
        self.appURL = appURL
        self.version = version
        self.managesEngine = managesEngine
        let override = ProcessInfo.processInfo.environment["MACPAPER_UPDATE_FEED"].flatMap(URL.init(string:))
        self.feed = feed ?? override
            ?? URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest")!
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

    // MARK: - Checking

    /// On launch: checks if the last check was long enough ago.
    func checkIfDue() {
        guard isAvailable else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
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
                UserDefaults.standard.set(self.lastChecked, forKey: "updateLastChecked")
                guard Self.isNewer(release.version, than: self.version) else {
                    self.phase = .upToDate
                    if userInitiated { self.app?.show(notice: "MacPaperEngine \(self.version) is the latest version") }
                    return
                }
                self.pending = release
                if self.installsAutomatically || userInitiated {
                    try await self.download(release)
                } else {
                    self.phase = .available(version: release.version)
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
    /// wallpaper is back within a second or two and the next window is the new version.
    func installOnQuit() {
        guard installsAutomatically, readyVersion != nil else { return }
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
