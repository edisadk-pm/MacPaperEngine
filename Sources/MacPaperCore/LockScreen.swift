import Foundation

public struct LockScreenRecord: Codable, Equatable {
    /// The wallpaper currently installed for the lock screen, if any.
    public var wallpaperID: String?
    public var name: String?
    public var preparing = false
    public var error: String?
    /// Set when a picture was installed as the system wallpaper instead of an Aerial video.
    /// Older records lack it, and were all Aerials.
    public var isStill: Bool?

    public init() {}

    public var isInstalled: Bool { wallpaperID != nil }
    public var usesAerial: Bool { isInstalled && isStill != true }
}

/// Puts a video on the lock screen by registering it as an Aerial in the current user's wallpaper
/// store, because the lock screen is drawn by macOS and hides every app's windows. Pictures and
/// dynamic wallpapers need no Aerial: they become the system wallpaper directly.
///
/// None of this is a public API. It relies on the file layout macOS 26 and later use, and a major
/// macOS update could change it.
public enum LockScreen {
    public enum Failure: LocalizedError {
        case storeUnreadable, manifestUnreadable

        public var errorDescription: String? {
            switch self {
            case .storeUnreadable: "macOS's wallpaper settings couldn't be read."
            case .manifestUnreadable: "macOS's Aerial list couldn't be read."
            }
        }
    }

    private static let assetID = "6D616370-6170-4572-8000-000000000001"
    private static let categoryID = "6D616370-6170-4572-8000-000000000002"
    private static let subcategoryID = "6D616370-6170-4572-8000-000000000003"

    private static let wallpaperRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.wallpaper")
    private static let aerials = wallpaperRoot.appendingPathComponent("aerials")
    private static let manifest = aerials.appendingPathComponent("manifest/entries.json")
    private static let videoURL = aerials.appendingPathComponent("videos/\(assetID).mov")
    public static let thumbnailURL = aerials.appendingPathComponent("thumbnails/\(assetID).png")
    private static let store = wallpaperRoot.appendingPathComponent("Store/Index.plist")

    /// Moves a prepared HEVC `.mov` into place and selects it as the system wallpaper. The
    /// thumbnail must already be at `thumbnailURL`.
    public static func install(preparedVideo: URL, name: String) throws {
        let files = FileManager.default
        try files.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? files.removeItem(at: videoURL)
        try files.moveItem(at: preparedVideo, to: videoURL)

        try writeManifestEntry(name: name)
        try backUpStoreIfNeeded()
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        try select(provider: "com.apple.wallpaper.choice.aerials", configuration: configuration)
        restartAgent()
    }

    /// Makes a picture the system wallpaper, the same way System Settings records one. macOS then
    /// handles a dynamic HEIC's changes on the lock screen itself.
    public static func install(image: URL) throws {
        try backUpStoreIfNeeded()
        // A video installed earlier leaves an Aerial behind that is no longer needed.
        try? removeManifestEntry()
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: thumbnailURL)

        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile", "url": ["relative": image.absoluteString]],
            format: .binary, options: 0)
        try select(provider: "com.apple.wallpaper.choice.image", configuration: configuration)
        restartAgent()
    }

    public static func uninstall() {
        try? removeManifestEntry()
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: thumbnailURL)
        restoreStore()
        restartAgent()
    }

    /// macOS periodically replaces its Aerial list with a fresh download, which drops our entry.
    /// Returns true if the entry had to be put back.
    @discardableResult
    public static func repairManifestIfNeeded(name: String) -> Bool {
        guard let data = try? Data(contentsOf: manifest),
              data.range(of: Data(assetID.utf8)) == nil,
              (try? writeManifestEntry(name: name)) != nil else { return false }
        restartAgent()
        return true
    }

    public static var manifestModified: Date? {
        (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Manifest

    private static func loadManifest() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: manifest),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.manifestUnreadable
        }
        return parsed
    }

    private static func saveManifest(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: manifest, options: .atomic)
    }

    private static func writeManifestEntry(name: String) throws {
        var entries = try loadManifest()
        let thumbnail = thumbnailURL.absoluteString

        var categories = (entries["categories"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != categoryID }
        categories.append([
            "id": categoryID,
            "localizedNameKey": "MacPaperEngine",
            "localizedDescriptionKey": "Your MacPaperEngine wallpaper",
            "preferredOrder": 999,
            "previewImage": thumbnail,
            "representativeAssetID": assetID,
            "subcategories": [[
                "id": subcategoryID,
                "localizedNameKey": "MacPaperEngine",
                "localizedDescriptionKey": "Your MacPaperEngine wallpaper",
                "preferredOrder": 0,
                "previewImage": thumbnail,
                "representativeAssetID": assetID,
            ]],
        ])

        var assets = (entries["assets"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != assetID }
        assets.append([
            "id": assetID,
            "accessibilityLabel": name,
            "localizedNameKey": name,
            "shotID": "MACPAPER",
            "showInTopLevel": true,
            "includeInShuffle": false,
            "preferredOrder": 0,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "pointsOfInterest": [String: String](),
            "previewImage": thumbnail,
            "url-4K-SDR-240FPS": videoURL.absoluteString,
        ])

        entries["categories"] = categories
        entries["assets"] = assets
        try saveManifest(entries)
    }

    private static func removeManifestEntry() throws {
        var entries = try loadManifest()
        entries["categories"] = (entries["categories"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != categoryID }
        entries["assets"] = (entries["assets"] as? [[String: Any]] ?? []).filter { $0["id"] as? String != assetID }
        try saveManifest(entries)
    }

    // MARK: - Wallpaper store

    private static func backUpStoreIfNeeded() throws {
        guard !FileManager.default.fileExists(atPath: Paths.systemWallpaperBackup.path) else { return }
        Paths.prepare()
        try FileManager.default.copyItem(at: store, to: Paths.systemWallpaperBackup)
    }

    private static func restoreStore() {
        guard let backup = try? Data(contentsOf: Paths.systemWallpaperBackup),
              (try? backup.write(to: store, options: .atomic)) != nil else { return }
        try? FileManager.default.removeItem(at: Paths.systemWallpaperBackup)
    }

    private static func select(provider: String, configuration: Data) throws {
        guard let data = try? Data(contentsOf: store),
              var root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.storeUnreadable
        }

        let now = Date()
        let entry: [String: Any] = [
            "Type": "linked",
            "Linked": [
                "Content": ["Choices": [[
                    "Provider": provider,
                    "Configuration": configuration,
                    "Files": [Any](),
                ]]],
                "LastSet": now,
                "LastUse": now,
            ],
        ]

        root["SystemDefault"] = entry
        root["AllSpacesAndDisplays"] = entry
        if let displays = root["Displays"] as? [String: Any] {
            root["Displays"] = displays.mapValues { _ in entry }
        }
        if let spaces = root["Spaces"] as? [String: [String: Any]] {
            root["Spaces"] = spaces.mapValues { space -> [String: Any] in
                var space = space
                if space["Default"] != nil { space["Default"] = entry }
                if let displays = space["Displays"] as? [String: Any] {
                    space["Displays"] = displays.mapValues { _ in entry }
                }
                return space
            }
        }

        let output = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try output.write(to: store, options: .atomic)
    }

    private static func restartAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
        task.waitUntilExit()
    }
}
