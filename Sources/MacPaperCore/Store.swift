import Foundation

public enum Paths {
    /// `MACPAPER_HOME` lets a development build run against a throwaway data folder.
    public static let root: URL = {
        if let home = ProcessInfo.processInfo.environment["MACPAPER_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacPaper", isDirectory: true)
    }()

    public static let videos = root.appendingPathComponent("Videos", isDirectory: true)
    public static let images = root.appendingPathComponent("Pictures", isDirectory: true)
    public static let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
    public static let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
    public static let state = root.appendingPathComponent("state.json")
    public static let stats = root.appendingPathComponent("stats.json")
    public static let lockScreen = root.appendingPathComponent("lockscreen.json")
    public static let systemWallpaperBackup = root.appendingPathComponent("SystemWallpaperBackup.plist")

    /// Bundled files live in the engine's bundle, which is nested inside the app, so both
    /// processes find them.
    private static let engineResources: URL = {
        let main = Bundle.main.bundleURL
        let engine = main.lastPathComponent == "MacPaperEngine.app"
            ? main
            : main.appendingPathComponent("Contents/Library/LoginItems/MacPaperEngine.app")
        return engine.appendingPathComponent("Contents/Resources", isDirectory: true)
    }()

    public static let footage = engineResources.appendingPathComponent("Footage", isDirectory: true)
    public static let includedDynamic = engineResources.appendingPathComponent("Dynamic", isDirectory: true)

    public static func prepare() {
        for dir in [videos, images, thumbnails] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public enum Store {
    public static func loadState() -> AppState {
        load(AppState.self, from: Paths.state) ?? AppState()
    }

    public static func save(_ state: AppState) {
        write(state, to: Paths.state)
    }

    public static func loadStats() -> Stats {
        load(Stats.self, from: Paths.stats) ?? Stats()
    }

    public static func save(_ stats: Stats) {
        write(stats, to: Paths.stats)
    }

    public static func loadLockScreen() -> LockScreenRecord {
        load(LockScreenRecord.self, from: Paths.lockScreen) ?? LockScreenRecord()
    }

    public static func save(_ record: LockScreenRecord) {
        write(record, to: Paths.lockScreen)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        Paths.prepare()
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The two processes share `state.json` and nudge each other with distributed notifications.
public enum IPC {
    public static let appBundleID = "app.macpaper.MacPaper"
    public static let engineBundleID = "app.macpaper.MacPaper.Engine"

    public static let settingsChanged = Notification.Name("app.macpaper.settings-changed")
    public static let statusChanged = Notification.Name("app.macpaper.status-changed")
    public static let statusRequested = Notification.Name("app.macpaper.status-requested")
    public static let quitEngine = Notification.Name("app.macpaper.quit-engine")
    public static let togglePause = Notification.Name("app.macpaper.toggle-pause")

    public static func post(_ name: Notification.Name, object: String? = nil) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: object, userInfo: nil, deliverImmediately: true)
    }

    public static func encode(_ status: EngineStatus) -> String? {
        (try? JSONEncoder().encode(status)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func decodeStatus(_ string: String?) -> EngineStatus? {
        guard let data = string?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EngineStatus.self, from: data)
    }
}
