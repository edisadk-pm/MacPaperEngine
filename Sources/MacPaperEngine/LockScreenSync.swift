import AppKit
import AVFoundation
import ImageIO
import MacPaperCore
import UniformTypeIdentifiers

/// Keeps the lock screen showing the main display's wallpaper.
final class LockScreenSync {
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?
    private var busy = false
    private var latest: AppState?
    private var lastManifestDate: Date?
    private var lastRepairCheck = CACurrentMediaTime()

    private static let debounce = 1.5
    private static let repairInterval: CFTimeInterval = 60

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func update(state: AppState, mainDisplay: String?) {
        pending?.cancel()
        pending = nil
        guard !busy else {
            latest = state
            return
        }

        let record = Store.loadLockScreen()
        guard state.settings.lockScreen else {
            if record.isInstalled { uninstall() }
            return
        }

        guard let wallpaper = state.wallpaper(forDisplay: mainDisplay),
              record.wallpaperID != wallpaper.id else { return }

        let smooth = state.settings.smoothLoops
        let work = DispatchWorkItem { [weak self] in self?.install(wallpaper, smoothLoops: smooth) }
        pending = work
        // Clicking through the library shouldn't convert every video along the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    func repairIfNeeded() {
        let now = CACurrentMediaTime()
        guard !busy, now - lastRepairCheck > Self.repairInterval else { return }
        lastRepairCheck = now

        let modified = LockScreen.manifestModified
        guard modified != lastManifestDate else { return }
        lastManifestDate = modified

        let record = Store.loadLockScreen()
        guard record.usesAerial, let name = record.name else { return }
        LockScreen.repairManifestIfNeeded(name: name)
    }

    private func install(_ wallpaper: Wallpaper, smoothLoops: Bool) {
        busy = true
        var record = Store.loadLockScreen()
        record.preparing = true
        record.error = nil
        Store.save(record)
        onChange()

        Task.detached(priority: .utility) { [weak self] in
            var result = LockScreenRecord()
            do {
                if wallpaper.kind == .image || wallpaper.kind == .dynamic {
                    guard let image = wallpaper.fileURL else { throw LockVideoPreparer.Failure.noVideo }
                    try LockScreen.install(image: image)
                    result.isStill = true
                } else {
                    let prepared = try await LockVideoPreparer.prepare(wallpaper, smoothLoops: smoothLoops)
                    try LockScreen.install(preparedVideo: prepared, name: wallpaper.name)
                }
                result.wallpaperID = wallpaper.id
                result.name = wallpaper.name
            } catch {
                result.wallpaperID = record.wallpaperID
                result.name = record.name
                result.isStill = record.isStill
                result.error = error.localizedDescription
            }
            let finished = result
            await MainActor.run { self?.finish(finished) }
        }
    }

    private func uninstall() {
        busy = true
        Task.detached(priority: .utility) { [weak self] in
            LockScreen.uninstall()
            await MainActor.run { self?.finish(LockScreenRecord()) }
        }
    }

    private func finish(_ record: LockScreenRecord) {
        Store.save(record)
        busy = false
        lastManifestDate = LockScreen.manifestModified
        onChange()
        if let latest {
            self.latest = nil
            update(state: latest, mainDisplay: NSScreen.screens.first?.displayUUID)
        }
    }
}

enum LockVideoPreparer {
    enum Failure: LocalizedError {
        case noVideo, exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "This wallpaper's file is missing."
            case .exportFailed(let reason): "The video couldn't be converted: \(reason)"
            }
        }
    }

    /// Apple's own Aerials run for minutes; a clip this long outlasts the time before the display
    /// sleeps on the lock screen.
    private static let minimumDuration = 90.0

    static func prepare(_ wallpaper: Wallpaper, smoothLoops: Bool) async throws -> URL {
        Paths.prepare()
        guard let source = wallpaper.playbackURL(smoothLoops: smoothLoops) else { throw Failure.noVideo }
        let encoded = Paths.root.appendingPathComponent("lockscreen-encoded.mov")
        let output = Paths.root.appendingPathComponent("lockscreen-prepared.mov")
        defer { try? FileManager.default.removeItem(at: encoded) }
        try? FileManager.default.removeItem(at: output)

        var asset = AVURLAsset(url: source)
        guard var track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }

        if !(try await isHEVC(track)) {
            try? FileManager.default.removeItem(at: encoded)
            try await export(asset, preset: AVAssetExportPresetHEVCHighestQuality, to: encoded)
            asset = AVURLAsset(url: encoded)
            guard let converted = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
            track = converted
        }

        try await writeThumbnail(asset)

        // Repeating is a stream copy, so this step costs almost nothing.
        let composition = AVMutableComposition()
        guard let out = composition.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noVideo
        }
        let range = try await track.load(.timeRange)
        out.preferredTransform = try await track.load(.preferredTransform)
        var cursor = CMTime.zero
        repeat {
            try out.insertTimeRange(range, of: track, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        } while cursor.seconds < minimumDuration

        try await export(composition, preset: AVAssetExportPresetPassthrough, to: output)
        return output
    }

    private static func isHEVC(_ track: AVAssetTrack) async throws -> Bool {
        guard let format = try await track.load(.formatDescriptions).first else { return false }
        return CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC
    }

    private static func export(_ asset: AVAsset, preset: String, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw Failure.exportFailed("no compatible export preset")
        }
        session.outputURL = url
        session.outputFileType = .mov
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            throw Failure.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    private static func writeThumbnail(_ asset: AVAsset) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 400)
        let (image, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        try saveThumbnail(image)
    }

    private static func saveThumbnail(_ image: CGImage) throws {
        let url = LockScreen.thumbnailURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
