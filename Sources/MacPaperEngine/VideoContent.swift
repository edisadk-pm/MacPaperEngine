import AVFoundation
import CoreMedia
import MacPaperCore

/// Plays a video on a loop by reading *compressed* samples and handing them to a hardware-decoding
/// layer only a few frames before they are due.
///
/// Almost all of a video wallpaper's memory is decoded frames, held by macOS's decoder process, and
/// their number grows with how far ahead the decoder is fed. `AVPlayer` offers no way to limit
/// that; feeding by hand does.
final class VideoContent: WallpaperContent {
    var layer: CALayer { displayLayer }
    var onReady: (() -> Void)?
    let isAnimated = true

    private struct Pass {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
    }

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "app.macpaper.video", qos: .userInitiated)
    private let asset: AVURLAsset
    private var timebase: CMTimebase?

    /// How many frames to keep queued ahead of the playhead. Starts small to save memory and
    /// grows only if this Mac actually drops frames at that size.
    private static let initialFramesAhead = 6.0
    private static let maximumFramesAhead = 30.0
    private static let adaptationInterval = 4.0
    private static let minimumLead = 0.08
    private static let prerollSamples = 6

    private var bounds = CGRect.zero
    private var rotation: CGFloat = 0

    // Everything below is touched only on `queue`.
    private var track: AVAssetTrack?
    private var frameRate = 30.0
    private var framesAhead = VideoContent.initialFramesAhead
    private var bufferHigh = 0.2
    private var lastDroppedCount: Int?
    private var current: Pass?
    private var standby: Pass?
    private var preparingStandby = false
    private var loopOffset = CMTime.zero
    private var loopFirstPTS = CMTime.invalid
    private var loopEnd = CMTime.invalid
    private var newestDecodeTime = CMTime.zero
    private var enqueuedCount = 0
    private var rolling = false
    private var requesting = false
    private var rearmScheduled = false
    private var consecutiveFailures = 0
    private var paused = false
    private var speed: Double
    private var stopped = false

    init(url: URL, settings: WallpaperSettings) {
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        renderer = displayLayer.sampleBufferRenderer
        speed = settings.speed
        displayLayer.videoGravity = Self.gravity(settings.scaling)

        var created: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &created)
        timebase = created
        displayLayer.controlTimebase = created
    }

    private static func gravity(_ scaling: Scaling) -> AVLayerVideoGravity {
        switch scaling {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }

    func start() {
        Task { [weak self, asset] in
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let frameRate = (try? await track.load(.nominalFrameRate)) ?? 30
            self?.begin(track: track, transform: transform, frameRate: Double(frameRate))
        }
    }

    private func begin(track: AVAssetTrack, transform: CGAffineTransform, frameRate: Double) {
        // Phone footage stores its orientation as metadata, which this layer doesn't honour.
        // AVFoundation's angle is in y-down space, and AppKit layers are y-up, hence the sign.
        let angle = -atan2(transform.b, transform.a)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rotation = angle
            self.layout(in: self.bounds)
        }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.track = track
            self.frameRate = max(frameRate, 1)
            self.updateLead()
            self.arm()
            self.scheduleAdaptation()
        }
    }

    func layout(in bounds: CGRect) {
        self.bounds = bounds
        let quarterTurn = abs(abs(rotation) - .pi / 2) < 0.01
        let size = quarterTurn ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(origin: .zero, size: size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotation))
        CATransaction.commit()
    }

    func apply(settings: WallpaperSettings) {
        displayLayer.videoGravity = Self.gravity(settings.scaling)
        queue.async { [weak self, speed = settings.speed] in
            guard let self, self.speed != speed else { return }
            self.speed = speed
            self.applyRate()
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            guard let self, self.paused != paused else { return }
            self.paused = paused
            self.applyRate()
            if !paused { self.arm() }
        }
    }

    func stop() {
        onReady = nil
        queue.sync {
            stopped = true
            renderer.stopRequestingMediaData()
            renderer.flush()
            closePasses()
        }
    }

    func recoverIfNeeded() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.track != nil,
                  self.renderer.status == .failed else { return }
            self.restart()
        }
    }

    // MARK: - Adapting the lead (on `queue`)

    private func updateLead() {
        bufferHigh = max(Self.minimumLead, framesAhead / frameRate)
    }

    private func scheduleAdaptation() {
        queue.asyncAfter(deadline: .now() + Self.adaptationInterval) { [weak self] in
            self?.adaptLead()
        }
    }

    private func adaptLead() {
        guard !stopped else { return }
        scheduleAdaptation()
        guard !paused, rolling, framesAhead < Self.maximumFramesAhead,
              #available(macOS 14.4, *) else { return }
        renderer.loadVideoPerformanceMetrics { [weak self] metrics in
            guard let self, let metrics else { return }
            self.queue.async { self.recordDrops(metrics.numberOfDroppedFrames) }
        }
    }

    private func recordDrops(_ total: Int) {
        // The first reading only sets the baseline, which skips the expected startup drops.
        if let last = lastDroppedCount, total - last >= 2 {
            framesAhead = min(framesAhead + 6, Self.maximumFramesAhead)
            updateLead()
        }
        lastDroppedCount = total
    }

    // MARK: - Feeding (on `queue`)

    private func applyRate() {
        guard let timebase else { return }
        CMTimebaseSetRate(timebase, rate: paused || !rolling ? 0 : speed)
    }

    private func arm() {
        guard !stopped, !requesting, track != nil else { return }
        requesting = true
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feed() }
    }

    private func disarm() {
        guard requesting else { return }
        requesting = false
        renderer.stopRequestingMediaData()
    }

    private func feed() {
        guard !stopped, let timebase else { return }

        while renderer.isReadyForMoreMediaData {
            if rolling {
                // Lead is measured in decode time, not presentation time. With B-frames the newest
                // sample's presentation time runs well past what can actually be decoded, and
                // stopping on that starves the decoder.
                let lead = CMTimeGetSeconds(CMTimeSubtract(newestDecodeTime, CMTimebaseGetTime(timebase)))
                if lead > bufferHigh {
                    disarm()
                    // While paused the playhead is frozen, so nothing needs a refill until resume.
                    if !paused { scheduleRearm(after: (lead - bufferHigh / 2) / max(speed, 0.1)) }
                    return
                }
            }

            let fed: Bool = autoreleasepool {
                guard let sample = nextSample() else { return false }
                renderer.enqueue(sample)
                return true
            }
            guard fed else {
                disarm()
                return
            }

            enqueuedCount += 1
            if !rolling, enqueuedCount >= Self.prerollSamples {
                rolling = true
                applyRate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.onReady?()
                }
            }
        }
    }

    private func scheduleRearm(after delay: Double) {
        guard !rearmScheduled else { return }
        rearmScheduled = true
        queue.asyncAfter(deadline: .now() + max(delay, 0.01)) { [weak self] in
            guard let self else { return }
            self.rearmScheduled = false
            if !self.paused { self.arm() }
        }
    }

    private func nextSample() -> CMSampleBuffer? {
        while consecutiveFailures < 2 {
            if current == nil, !beginPass() {
                consecutiveFailures += 1
                continue
            }
            guard let sample = current?.output.copyNextSampleBuffer() else {
                finishPass()
                continue
            }
            guard CMSampleBufferGetNumSamples(sample) > 0,
                  let retimed = retime(sample) else { continue }
            consecutiveFailures = 0
            return retimed
        }
        return nil
    }

    /// Opening a reader takes long enough to starve a short queue, so each loop's reader is
    /// opened early, off this queue, and is simply swapped in at the seam.
    private static func makePass(asset: AVAsset, track: AVAssetTrack) -> Pass? {
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        // No output settings means compressed passthrough: no decoding happens in this process.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        return Pass(reader: reader, output: output)
    }

    private func beginPass() -> Bool {
        guard let track else { return false }
        let next = standby ?? Self.makePass(asset: asset, track: track)
        standby = nil
        guard let next else { return false }
        current = next
        loopFirstPTS = .invalid
        loopEnd = .invalid
        prepareStandby()
        return true
    }

    private func prepareStandby() {
        guard standby == nil, !preparingStandby, let track else { return }
        preparingStandby = true
        DispatchQueue.global(qos: .utility).async { [weak self, asset] in
            let pass = Self.makePass(asset: asset, track: track)
            guard let self else {
                pass?.reader.cancelReading()
                return
            }
            self.queue.async {
                self.preparingStandby = false
                if self.stopped {
                    pass?.reader.cancelReading()
                } else {
                    self.standby = pass
                }
            }
        }
    }

    private func finishPass() {
        current?.reader.cancelReading()
        current = nil
        guard loopEnd.isValid, loopFirstPTS.isValid else {
            // A pass that produced nothing would otherwise spin forever.
            consecutiveFailures += 1
            return
        }
        loopOffset = CMTimeAdd(loopOffset, CMTimeSubtract(loopEnd, loopFirstPTS))
    }

    private func closePasses() {
        current?.reader.cancelReading()
        standby?.reader.cancelReading()
        current = nil
        standby = nil
    }

    private func retime(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                               entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing,
                                               entriesNeededOut: &count)

        // Shifts this pass's timestamps so that it starts where the previous pass ended.
        if !loopFirstPTS.isValid { loopFirstPTS = timing[0].presentationTimeStamp }
        let shift = CMTimeSubtract(loopOffset, loopFirstPTS)

        for index in timing.indices {
            let pts = timing[index].presentationTimeStamp
            let duration = timing[index].duration
            let end = duration.isValid ? CMTimeAdd(pts, duration) : pts
            if !loopEnd.isValid || CMTimeCompare(end, loopEnd) > 0 { loopEnd = end }

            timing[index].presentationTimeStamp = CMTimeAdd(pts, shift)
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, shift)
            }
            let decodeTime = timing[index].decodeTimeStamp.isValid
                ? timing[index].decodeTimeStamp
                : timing[index].presentationTimeStamp
            if CMTimeCompare(decodeTime, newestDecodeTime) > 0 { newestDecodeTime = decodeTime }
        }

        // The clock starts at the first sample of playback.
        if enqueuedCount == 0, let timebase {
            CMTimebaseSetTime(timebase, time: timing[0].presentationTimeStamp)
        }

        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: sample,
                                              sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing,
                                              sampleBufferOut: &copy)
        return copy
    }

    private func restart() {
        disarm()
        renderer.flush()
        closePasses()
        loopOffset = .zero
        newestDecodeTime = .zero
        enqueuedCount = 0
        rolling = false
        lastDroppedCount = nil
        consecutiveFailures = 0
        applyRate()
        arm()
    }
}
