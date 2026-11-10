import AVFoundation
import ImageIO
import MacPaperCore
import UniformTypeIdentifiers

enum Importer {
    /// Formats that hold an animation and become video when they have more than one frame.
    static let animatedImageTypes: [UTType] = [.gif, .webP, .png]
    static let acceptedTypes: [UTType] = [.movie, .image]

    /// What the open panel offers on each page.
    static func types(for category: Wallpaper.Category) -> [UTType] {
        switch category {
        case .videos: [.movie] + animatedImageTypes
        case .dynamic: [.heic, .heif]
        case .pictures: [.image]
        }
    }

    enum Failure: LocalizedError {
        case unsupported, unreadable, unreadableImage, encoderFailed

        var errorDescription: String? {
            switch self {
            case .unsupported: "This file type isn't supported. Use a video (MP4, MOV), an animated image (GIF, WebP, APNG) or a picture (JPEG, PNG, HEIC)."
            case .unreadable: "macOS can't decode this video. H.264 and HEVC are the safest formats."
            case .unreadableImage: "macOS can't open this picture."
            case .encoderFailed: "The animated image couldn't be converted."
            }
        }
    }

    static func importFile(_ file: URL, name: String? = nil,
                           source: Wallpaper.Source? = nil) async throws -> Wallpaper {
        Paths.prepare()
        let id = UUID().uuidString
        let ext = file.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let name = name ?? file.deletingPathExtension().lastPathComponent

        if type?.conforms(to: .movie) == true {
            let fileName = "\(id).\(ext)"
            let destination = Paths.videos.appendingPathComponent(fileName)
            // `copyItem` clones on APFS, so a big video takes no extra disk space.
            try FileManager.default.copyItem(at: file, to: destination)
            return try await describeVideo(id: id, name: name, fileName: fileName, animated: nil, source: source)
        }

        guard let type, type.conforms(to: .image) else { throw Failure.unsupported }
        guard let image = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetCount(image) > 0 else { throw Failure.unreadableImage }

        if type.conforms(to: .heif) || type.conforms(to: .heic), DynamicSchedule.read(from: image) != nil {
            return try await importStill(file, image: image, kind: .dynamic, id: id, ext: ext, name: name, source: source)
        }

        if CGImageSourceGetCount(image) > 1, animatedImageTypes.contains(where: { type.conforms(to: $0) }) {
            // Animated images become video so that they reach the same hardware decode path,
            // instead of holding every decoded frame in memory.
            let fileName = "\(id).mp4"
            try await AnimatedImageTranscoder.transcode(file, to: Paths.videos.appendingPathComponent(fileName))
            return try await describeVideo(id: id, name: name, fileName: fileName, animated: true, source: source)
        }

        return try await importStill(file, image: image, kind: .image, id: id, ext: ext, name: name, source: source)
    }

    private static func describeVideo(id: String, name: String, fileName: String, animated: Bool?,
                                      source: Wallpaper.Source?) async throws -> Wallpaper {
        let destination = Paths.videos.appendingPathComponent(fileName)
        do {
            let asset = AVURLAsset(url: destination)
            guard let track = try await asset.loadTracks(withMediaType: .video).first,
                  try await asset.load(.isPlayable) else { throw Failure.unreadable }

            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let shown = size.applying(transform)
            let duration = try await asset.load(.duration).seconds

            let wallpaper = Wallpaper(id: id, name: name, kind: .video, file: fileName,
                                      width: Int(abs(shown.width)), height: Int(abs(shown.height)),
                                      duration: duration, animated: animated, source: source)
            try await writeThumbnail(for: asset, duration: duration, to: wallpaper.thumbnailURL)
            return wallpaper
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw (error as? Failure) ?? Failure.unreadable
        }
    }

    private static func importStill(_ file: URL, image: CGImageSource, kind: Wallpaper.Kind, id: String,
                                    ext: String, name: String, source: Wallpaper.Source?) async throws -> Wallpaper {
        let fileName = "\(id).\(ext.isEmpty ? "jpg" : ext)"
        let destination = Paths.images.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: file, to: destination)

        let index = CGImageSourceGetPrimaryImageIndex(image)
        let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any]
        var width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }

        let wallpaper = Wallpaper(id: id, name: name, kind: kind, file: fileName,
                                  width: width, height: height, source: source)
        guard await Thumbnails.writeImageThumbnail(of: destination, kind: kind, to: wallpaper.thumbnailURL) else {
            try? FileManager.default.removeItem(at: destination)
            throw Failure.unreadableImage
        }
        return wallpaper
    }

    static func writeThumbnail(for asset: AVAsset, duration: Double, to url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = Thumbnails.maximumSize
        let time = CMTime(seconds: min(1, duration * 0.25), preferredTimescale: 600)
        let (image, _) = try await generator.image(at: time)
        Thumbnails.write(image, to: url)
    }
}

enum Thumbnails {
    static let maximumSize = CGSize(width: 480, height: 300)
    /// Pictures are often square or portrait, so they get more pixels to fill a wide tile.
    static let imageMaximumPixels = 720

    static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    /// For a dynamic wallpaper this is its daytime picture.
    @discardableResult
    static func writeImageThumbnail(of file: URL, kind: Wallpaper.Kind, to url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return false }
            let index = kind == .dynamic
                ? DynamicSchedule.read(from: source)?.previewIndex ?? 0
                : CGImageSourceGetPrimaryImageIndex(source)
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: imageMaximumPixels,
            ] as CFDictionary) else { return false }
            Paths.prepare()
            write(image, to: url)
            return true
        }.value
    }

    /// Thumbnails for things that didn't come through an import are made the first time they're
    /// needed.
    static func ensure(_ wallpaper: Wallpaper) async -> URL {
        let url = wallpaper.thumbnailURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        switch wallpaper.kind {
        case .video:
            if let video = wallpaper.fileURL {
                Paths.prepare()
                try? await Importer.writeThumbnail(for: AVURLAsset(url: video), duration: wallpaper.duration, to: url)
            }
        case .image, .dynamic:
            if let file = wallpaper.fileURL {
                await writeImageThumbnail(of: file, kind: wallpaper.kind, to: url)
            }
        }
        return url
    }
}

enum AnimatedImageTranscoder {
    static func transcode(_ source: URL, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try run(source, to: destination)
        }.value
    }

    private static func run(_ source: URL, to destination: URL) throws {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw Importer.Failure.unsupported }
        let count = CGImageSourceGetCount(image)
        guard count > 1 else { throw Importer.Failure.unsupported }
        guard let first = CGImageSourceCreateImageAtIndex(image, 0, nil) else { throw Importer.Failure.unsupported }

        // H.264 needs even dimensions.
        let width = first.width & ~1
        let height = first.height & ~1
        guard width > 0, height > 0 else { throw Importer.Failure.unsupported }

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_500_000, width * height * 6),
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Importer.Failure.encoderFailed }
        writer.startSession(atSourceTime: .zero)

        let timescale: CMTimeScale = 600
        var presentation = CMTime.zero
        do {
            for index in 0..<count {
                try autoreleasepool {
                    guard let frame = CGImageSourceCreateImageAtIndex(image, index, nil),
                          let pool = adaptor.pixelBufferPool else { throw Importer.Failure.encoderFailed }

                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    guard let buffer else { throw Importer.Failure.encoderFailed }
                    draw(frame, into: buffer, width: width, height: height)

                    while !input.isReadyForMoreMediaData {
                        if writer.status == .failed { throw Importer.Failure.encoderFailed }
                        usleep(2_000)
                    }
                    guard adaptor.append(buffer, withPresentationTime: presentation) else {
                        throw Importer.Failure.encoderFailed
                    }
                    let delay = frameDelay(image, at: index)
                    presentation = CMTimeAdd(presentation, CMTime(seconds: delay, preferredTimescale: timescale))
                }
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: presentation)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw Importer.Failure.encoderFailed
        }
    }

    private static func draw(_ frame: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return }
        // Video has no alpha, so transparent areas are flattened onto black.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func frameDelay(_ image: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any] else { return 0.1 }
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        ]
        for (container, unclamped, clamped) in containers {
            guard let values = properties[container] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0.1
            // Browsers treat near-zero delays as 100 ms, and GIF authors rely on that.
            return delay < 0.02 ? 0.1 : delay
        }
        return 0.1
    }
}
