import AVFoundation
import CoreImage
import MacPaperCore

/// Writes a copy of a video that loops with no visible jump.
///
/// The copy leaves out the last `fade` seconds and blends them into the first `fade` seconds
/// instead: it opens on the original's frame at `end - fade` and dissolves into the original's
/// own opening. Its last frame is the original's frame just before `end - fade`, which runs
/// straight on into its first, so the restart is invisible.
///
/// Done once, in the background, so playback stays a single plain video: no second decoder and
/// no extra memory.
enum LoopSmoother {
    enum Failure: LocalizedError {
        case noVideo, tooShort, failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "This video has no picture track."
            case .tooShort: "This video is too short to blend."
            case .failed(let reason): "Blending the loop failed: \(reason)"
            }
        }
    }

    static let minimumDuration = 0.5

    static func isNeeded(for wallpaper: Wallpaper) -> Bool {
        guard wallpaper.duration >= minimumDuration, let url = wallpaper.smoothLoopURL,
              wallpaper.fileURL != nil else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    /// How long the blend lasts: half a second, less for very short clips such as GIFs.
    static func fadeDuration(for duration: Double) -> Double {
        min(0.6, duration / 4)
    }

    static func make(for wallpaper: Wallpaper, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let source = wallpaper.fileURL, let output = wallpaper.smoothLoopURL else { throw Failure.noVideo }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let duration = try await asset.load(.duration)
        guard duration.seconds >= minimumDuration else { throw Failure.tooShort }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let dataRate = try await track.load(.estimatedDataRate)

        let job = Job(asset: asset, track: track, duration: duration, size: size, transform: transform,
                      bitRate: Int(max(Double(dataRate) * 1.2, 2_000_000)), output: output)
        try await Task.detached(priority: .utility) { try job.run(progress: progress) }.value
    }

    private struct Job: @unchecked Sendable {
        let asset: AVAsset
        let track: AVAssetTrack
        let duration: CMTime
        let size: CGSize
        let transform: CGAffineTransform
        let bitRate: Int
        let output: URL

        private static let decoded: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]

        func run(progress: @Sendable (Double) -> Void) throws {
            let fade = CMTime(seconds: LoopSmoother.fadeDuration(for: duration.seconds), preferredTimescale: 600)
            let cut = CMTimeSubtract(duration, fade)
            let body = try reader(CMTimeRange(start: .zero, end: cut))
            let tail = try reader(CMTimeRange(start: cut, end: duration))
            defer {
                body.reader.cancelReading()
                tail.reader.cancelReading()
            }

            let width = Int(size.width), height = Int(size.height)
            let temporary = output.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).mov")
            let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
            ])
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            writer.add(input)
            guard writer.startWriting() else { throw Failure.failed("the encoder wouldn't start") }
            writer.startSession(atSourceTime: .zero)

            // No colour management: unblended frames pass through untouched, so blended ones must
            // be mixed in the same space to match them.
            let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                              .cacheIntermediates: false])
            var lastTime = CMTime.zero
            do {
                while true {
                    let appended: Bool = try autoreleasepool {
                        guard let sample = body.output.copyNextSampleBuffer() else { return false }
                        guard let frame = CMSampleBufferGetImageBuffer(sample) else { return true }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        guard CMTimeCompare(time, cut) < 0 else { return true }

                        var result = frame
                        if CMTimeCompare(time, fade) < 0,
                           let ending = tail.output.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer),
                           let pool = adaptor.pixelBufferPool {
                            var mixed: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &mixed)
                            if let mixed {
                                let amount = max(0, min(1, time.seconds / fade.seconds))
                                let blended = CIImage(cvPixelBuffer: ending).applyingFilter("CIDissolveTransition", parameters: [
                                    kCIInputTargetImageKey: CIImage(cvPixelBuffer: frame),
                                    kCIInputTimeKey: amount,
                                ])
                                context.render(blended, to: mixed)
                                result = mixed
                            }
                        }

                        while !input.isReadyForMoreMediaData {
                            if writer.status == .failed { throw Failure.failed(writer.error?.localizedDescription ?? "the encoder stopped") }
                            usleep(2_000)
                        }
                        guard adaptor.append(result, withPresentationTime: time) else {
                            throw Failure.failed(writer.error?.localizedDescription ?? "a frame was refused")
                        }
                        lastTime = time
                        progress(min(time.seconds / cut.seconds, 1))
                        return true
                    }
                    if !appended { break }
                }
                guard body.reader.status == .completed else {
                    throw Failure.failed(body.reader.error?.localizedDescription ?? "the video couldn't be read")
                }
            } catch {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }

            input.markAsFinished()
            writer.endSession(atSourceTime: CMTimeCompare(lastTime, cut) < 0 ? cut : lastTime)
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: temporary)
                throw Failure.failed(writer.error?.localizedDescription ?? "the file couldn't be finished")
            }
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: temporary, to: output)
        }

        private func reader(_ range: CMTimeRange) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.decoded)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.failed("the video couldn't be read") }
            reader.add(output)
            guard reader.startReading() else {
                throw Failure.failed(reader.error?.localizedDescription ?? "the video couldn't be read")
            }
            return (reader, output)
        }
    }
}
