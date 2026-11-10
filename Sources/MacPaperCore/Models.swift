import Foundation

public enum Scaling: String, Codable, CaseIterable, Hashable {
    case fill, fit, stretch
}

public struct Wallpaper: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable {
        /// A looping video, including animated images converted on import.
        case video
        /// A still picture.
        case image
        /// A HEIC holding several pictures that change with the time of day or the appearance.
        case dynamic
    }

    /// The three groups the app shows.
    public enum Category: String, CaseIterable, Codable, Hashable {
        case videos, dynamic, pictures
    }

    /// Where a downloaded wallpaper came from, for credit and for spotting what's already here.
    public struct Source: Codable, Hashable {
        public enum Provider: String, Codable, Hashable {
            case wallhaven, pexels

            public var name: String {
                switch self {
                case .wallhaven: "Wallhaven"
                case .pexels: "Pexels"
                }
            }
        }

        public var provider: Provider
        public var remoteID: String
        public var pageURL: URL?
        public var author: String?

        public init(provider: Provider, remoteID: String, pageURL: URL? = nil, author: String? = nil) {
            self.provider = provider
            self.remoteID = remoteID
            self.pageURL = pageURL
            self.author = author
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// A file name inside the folder for this kind.
    public var file: String?
    public var width: Int
    public var height: Int
    public var duration: Double
    /// True for videos that were imported as a GIF, WebP or APNG.
    public var animated: Bool?
    public var source: Source?

    public init(id: String, name: String, kind: Kind, file: String? = nil,
                width: Int = 0, height: Int = 0, duration: Double = 0,
                animated: Bool? = nil, source: Source? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.file = file
        self.width = width
        self.height = height
        self.duration = duration
        self.animated = animated
        self.source = source
    }

    /// Ships with the app, so it can't be removed from the library.
    public var isBuiltInFootage: Bool { id.hasPrefix(FootageCatalog.idPrefix) }

    /// A dynamic wallpaper that ships with MacPaper.
    public var isIncluded: Bool { id.hasPrefix(IncludedDynamicCatalog.idPrefix) }

    /// Only things the user added can be removed.
    public var isRemovable: Bool { !isBuiltInFootage && !isIncluded }

    /// Videos move. Pictures and dynamic wallpapers are drawn once and left alone.
    public var isAnimated: Bool { kind == .video }

    public var category: Category {
        switch kind {
        case .video: .videos
        case .dynamic: .dynamic
        case .image: .pictures
        }
    }

    public var fileURL: URL? {
        guard let file else { return nil }
        switch kind {
        case .video: return (isBuiltInFootage ? Paths.footage : Paths.videos).appendingPathComponent(file)
        case .dynamic where isIncluded: return Paths.includedDynamic.appendingPathComponent(file)
        case .image, .dynamic: return Paths.images.appendingPathComponent(file)
        }
    }

    public var thumbnailURL: URL {
        Paths.thumbnails.appendingPathComponent("\(id).jpg")
    }

    /// A copy of a video whose start blends in its end, so looping shows no jump. Made by the app
    /// in the background. Built-in clips are cut to loop already and have none.
    public var smoothLoopURL: URL? {
        guard kind == .video, !isBuiltInFootage else { return nil }
        return Paths.videos.appendingPathComponent("\(id).loop.mov")
    }

    /// The file to play: the smooth-loop copy when wanted and ready, otherwise the original.
    public func playbackURL(smoothLoops: Bool) -> URL? {
        if smoothLoops, let smooth = smoothLoopURL, FileManager.default.fileExists(atPath: smooth.path) {
            return smooth
        }
        return fileURL
    }
}

/// Video loops and dynamic wallpapers bundled with the app, listed in `catalog.json` files.
public struct FootageClip: Codable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let file: String
    public let width: Int
    public let height: Int
    public let duration: Double?
}

public enum FootageCatalog {
    static let idPrefix = "footage."

    public static let clips: [FootageClip] = {
        guard let data = try? Data(contentsOf: Paths.footage.appendingPathComponent("catalog.json")) else { return [] }
        return (try? JSONDecoder().decode([FootageClip].self, from: data)) ?? []
    }()

    public static let all: [Wallpaper] = clips.map {
        Wallpaper(id: $0.id, name: $0.name, kind: .video, file: $0.file,
                  width: $0.width, height: $0.height, duration: $0.duration ?? 0)
    }
}

/// Dynamic wallpapers bundled with the app, listed in `Dynamic/catalog.json`.
public enum IncludedDynamicCatalog {
    static let idPrefix = "included."

    public static let all: [Wallpaper] = {
        guard let data = try? Data(contentsOf: Paths.includedDynamic.appendingPathComponent("catalog.json")),
              let entries = try? JSONDecoder().decode([FootageClip].self, from: data) else { return [] }
        return entries.map {
            Wallpaper(id: $0.id, name: $0.name, kind: .dynamic, file: $0.file, width: $0.width, height: $0.height)
        }
    }()
}

public struct WallpaperSettings: Codable, Equatable {
    public var enabled = true
    public var sameOnAllDisplays = true
    public var sharedWallpaper: String?
    public var perDisplay: [String: String] = [:]

    public var scaling: Scaling = .fill
    public var speed = 1.0
    /// Hides the jump when a video restarts by blending its end into its start.
    public var smoothLoops = true

    public var pauseWhenCovered = true
    public var pauseOnBattery = false
    public var pauseInLowPower = true
    public var pauseWhenHot = true

    public var showMenuBarIcon = true
    public var lockScreen = false

    public init() {}

    // Missing keys fall back to defaults so that adding a setting never wipes a saved config.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WallpaperSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        sameOnAllDisplays = try c.decodeIfPresent(Bool.self, forKey: .sameOnAllDisplays) ?? d.sameOnAllDisplays
        sharedWallpaper = try c.decodeIfPresent(String.self, forKey: .sharedWallpaper)
        perDisplay = try c.decodeIfPresent([String: String].self, forKey: .perDisplay) ?? d.perDisplay
        scaling = try c.decodeIfPresent(Scaling.self, forKey: .scaling) ?? d.scaling
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        smoothLoops = try c.decodeIfPresent(Bool.self, forKey: .smoothLoops) ?? d.smoothLoops
        pauseWhenCovered = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenCovered) ?? d.pauseWhenCovered
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? d.pauseOnBattery
        pauseInLowPower = try c.decodeIfPresent(Bool.self, forKey: .pauseInLowPower) ?? d.pauseInLowPower
        pauseWhenHot = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenHot) ?? d.pauseWhenHot
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
        lockScreen = try c.decodeIfPresent(Bool.self, forKey: .lockScreen) ?? d.lockScreen
    }
}

public struct AppState: Codable, Equatable {
    public var settings = WallpaperSettings()
    public var library: [Wallpaper] = []

    public init() {}

    public func wallpaper(id: String?) -> Wallpaper? {
        guard let id else { return nil }
        if id.hasPrefix(IncludedDynamicCatalog.idPrefix) {
            return IncludedDynamicCatalog.all.first { $0.id == id }
        }
        return FootageCatalog.all.first { $0.id == id }
            ?? library.first { $0.id == id }
    }

    public func wallpaperID(forDisplay uuid: String?) -> String? {
        guard !settings.sameOnAllDisplays, let uuid else { return settings.sharedWallpaper }
        return settings.perDisplay[uuid] ?? settings.sharedWallpaper
    }

    public func wallpaper(forDisplay uuid: String?) -> Wallpaper? {
        wallpaper(id: wallpaperID(forDisplay: uuid))
    }
}

public struct Stats: Codable, Equatable {
    public var playSeconds: [String: Double] = [:]
    public var pausedSeconds = 0.0

    public init() {}

    public var totalPlayed: Double { playSeconds.values.reduce(0, +) }
}

public struct EngineStatus: Codable, Equatable {
    public enum State: String, Codable {
        case playing, paused, idle, off
        /// Only pictures or dynamic wallpapers are up, so there is nothing to play or pause.
        case still
    }

    public var state: State
    public var detail: String
    /// Paused with the Pause command rather than automatically.
    public var pausedByUser: Bool?

    public init(state: State, detail: String, pausedByUser: Bool = false) {
        self.state = state
        self.detail = detail
        self.pausedByUser = pausedByUser
    }

    public var label: String {
        switch state {
        case .playing: "Playing"
        case .paused: "Paused"
        case .idle: "Idle"
        case .off: "Off"
        case .still: "Showing"
        }
    }
}
