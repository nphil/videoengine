@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal
import QuartzCore

/// A frame pulled from the player, with what has to stay alive for the GPU to read it.
struct PulledFrame {
    /// Keeps the player's buffer valid until the GPU is done with it. Nil for a buffer the caller owns.
    var readOnly: CVReadOnlyPixelBuffer?
    var buffer: CVPixelBuffer
    var time: CMTime
}

/// What a pulled frame says about its picture.
struct FrameFacts {
    var picture: SourcePicture
    var matrix: YCbCrMatrix
    var fullRange: Bool
    /// The window of the frame that is shown and how it is turned; nil when the picture is refused.
    var geometry: PictureGeometry?

    /// `track` is how the video track says the frames are shown; frames of an unknown or upright track are taken as they are.
    init(buffer: CVPixelBuffer, presentationSize: CGSize, track: TrackOrientation = .known(.upright)) {
        let size = PixelSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let transfer = Self.attachment(buffer, kCVImageBufferTransferFunctionKey)
        let primaries = Self.attachment(buffer, kCVImageBufferColorPrimariesKey)
        let matrixName = Self.attachment(buffer, kCVImageBufferYCbCrMatrixKey)
        let pq = transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        let hlg = transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
        let wide = primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        let matrix: YCbCrMatrix
        if matrixName == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) {
            matrix = .bt709
        } else if matrixName == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
            matrix = .bt601
        } else if matrixName == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
            matrix = .bt2020
        } else {
            matrix = YCbCrMatrix.assumed(for: size)
        }
        let aspect = Self.pixelAspect(buffer)
        // A crop (the clean aperture), a turn (the track's transform), an odd size and a non-square pixel are all handled
        // by the geometry; what cannot be drawn is refused here, with the reason.
        var refusal: String?
        if !(videoRange || full) { refusal = "its frames are not 8-bit 4:2:0" }
        var orientation = PictureOrientation.upright
        let turned = Self.framesTurned(coded: size, pixelAspect: aspect, shown: presentationSize)
        switch OrientationVerdict.resolve(track: track, framesTurned: turned) {
        case .use(let turn): orientation = turn
        case .refuse(let reason): refusal = refusal ?? reason
        }
        let geometry = PictureGeometry.make(
            coded: size, clean: CVImageBufferGetCleanRect(buffer), pixelAspect: aspect, orientation: orientation
        )
        if geometry == nil { refusal = refusal ?? "its frames are smaller than 2x2 pixels" }
        var picture = SourcePicture(size: geometry?.size ?? size)
        picture.pixelAspect = geometry?.pixelAspect ?? aspect
        picture.range = pq || hlg || wide ? .hdr : .sdr
        picture.refusal = refusal
        self.picture = picture
        self.matrix = matrix
        self.fullRange = full
        self.geometry = geometry
    }

    /// Whether the player shows the frame with its sides the other way round from how it is coded, which says the player
    /// turns it by a quarter turn. Nil when that cannot be told: no shown size yet, or a nearly square picture.
    static func framesTurned(coded: PixelSize, pixelAspect: Double, shown: CGSize) -> Bool? {
        guard shown.width > 0, shown.height > 0 else { return nil }
        let longer = max(shown.width, shown.height)
        guard abs(shown.width - shown.height) >= 0.02 * longer else { return nil }
        let shownWide = shown.width >= shown.height
        let codedWide = Double(coded.width) * pixelAspect >= Double(coded.height)
        return shownWide != codedWide
    }

    private static func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    private static func pixelAspect(_ buffer: CVPixelBuffer) -> Double {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil),
              let dictionary = value as? [String: Any],
              let horizontal = (dictionary[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber)?.doubleValue,
              let vertical = (dictionary[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber)?.doubleValue,
              horizontal > 0, vertical > 0
        else { return 1 }
        return horizontal / vertical
    }
}

/// Counters the diagnostics line reports.
struct EnhanceStatistics: Equatable {
    var offered = 0
    var shown = 0
    var late = 0
    var skipped = 0
    var failed = 0
    var gpuSeconds = 0.0
    var gpuMaxSeconds = 0.0
}

/// One frame on its way through the GPU. Holds everything the GPU reads or writes until the frame is done, so a
/// buffer cannot go back to its pool, and a scaler cannot end its session, while the GPU still uses them.
final class FrameLease: @unchecked Sendable {
    let display: CVPixelBuffer
    let epoch: Int
    let deadline: CFTimeInterval
    let rank: Int?
    let kind: EnhanceUpscalerKind?
    var keep: [Any] = []

    init(display: CVPixelBuffer, epoch: Int, deadline: CFTimeInterval, rank: Int?, kind: EnhanceUpscalerKind?) {
        self.display = display
        self.epoch = epoch
        self.deadline = deadline
        self.rank = rank
        self.kind = kind
    }
}

private struct ChainKey: Equatable {
    var source: PixelSize
    var output: PixelSize
    var upscaler: EnhanceUpscalerKind?
}

/// The buffers the chain draws into for one source size, output size and scaler.
private final class Chain {
    let key: ChainKey
    /// What the player's own picture is replaced by: BGRA buffers the display layer shows.
    let display: PooledSurfaces
    /// The BGRA picture of the source when no scaler runs.
    let plain: PrivateSurfaces?

    init(key: ChainKey, display: PooledSurfaces, plain: PrivateSurfaces?) {
        self.key = key
        self.display = display
        self.plain = plain
    }
}

private enum GPUStatus {
    case untried, preparing, ready, failed
}

private enum GPUOutcome {
    case ready(EnhanceGPU)
    case failed(String)
}

private enum RungOutcome {
    case ready(any ScalerRung)
    case failed(String)
    /// Left out on purpose: it works, but not for live video on this picture.
    case skipped(String)
}

/// Receives the display link's ticks without keeping the enhancer alive.
@MainActor
private final class LinkTarget: NSObject {
    weak var owner: PictureEnhancer?

    @objc func fire(_ link: CADisplayLink) {
        guard let owner else {
            link.invalidate()
            return
        }
        owner.tick(link)
    }
}

/// Makes the picture of an SDR video better while it plays, on the device's GPU: a scaler that fills the display
/// with real detail, a contrast-adaptive sharpen and a deband, each optional and changeable at any time through
/// `options`. Nothing is on by default.
///
/// How it is used: put `layer` above the player's own layer with the same frame and video gravity, give the
/// enhancer the `AVPlayerItem` that plays, and tell it how many pixels the picture covers on screen.
///
/// ```swift
/// let enhancer = PictureEnhancer(options: EnhanceOptions(upscaler: .automatic, sharpen: 0.3), logger: logger)
/// videoView.layer.addSublayer(enhancer.layer)
/// enhancer.displaySize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
/// enhancer.attach(to: player.currentItem!)
/// for await state in enhancer.updates() { statusLabel.text = describe(state) }
/// ```
///
/// While the enhancer runs, `layer` shows the enhanced picture on top of the player's. Whenever it does not run (the
/// options are off, the video is HDR, the device is saving power, the chain cannot keep up) `layer` is empty and the
/// player's own picture shows through, so nothing is ever lost. Audio, subtitles and timing stay with the player.
/// Call `setActive(false)` when playback pauses or the app moves to the background, and `setActive(true)` when it
/// comes back: the enhancer then lets go of the player's frames, so the player does no extra work.
@MainActor
public final class PictureEnhancer {
    /// Shows the enhanced picture. Put it above the player's own layer, with the same frame and `videoGravity`.
    public let layer: AVSampleBufferDisplayLayer

    /// What to do to the picture. Change it at any time; the chain follows within a frame or two. A slider dragged in
    /// small steps is fine: sharpen and deband changes that come faster than ten a second are held back and only the
    /// newest is applied, and no strength change rebuilds the scaler. Reading it gives the newest value set.
    public var options: EnhanceOptions {
        get { requested }
        set {
            requested = newValue
            if let now = coalescer.request(newValue, current: applied, now: CACurrentMediaTime()) {
                apply(now)
            } else {
                scheduleFlush()
            }
        }
    }

    /// The pixels the picture covers on screen, which decides whether it is upscaled and how far. When it is empty the
    /// layer's own bounds times its `contentsScale` are used.
    public var displaySize: CGSize = .zero {
        didSet {
            if displaySize != oldValue { evaluate() }
        }
    }

    /// What the chain is doing now. Also published through `updates()`.
    public private(set) var state: EnhanceState = .idle {
        didSet {
            guard state != oldValue else { return }
            logPlan()
            for continuation in listeners.values { continuation.yield(state) }
        }
    }

    private let logger: EngineLogger
    private let power: @MainActor () -> HardwareCapabilities.Power
    private var listeners: [UUID: AsyncStream<EnhanceState>.Continuation] = [:]

    private var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var link: CADisplayLink?
    private var linkTarget: LinkTarget?
    private var isLive = false
    private var isActive = true
    private var lastFrameTime: CFTimeInterval = 0
    private var lastDisplaySeconds: Double?

    private var source: SourcePicture?
    private var knownTarget = PixelSize(width: 0, height: 0)
    private var gpu: EnhanceGPU?
    private var gpuStatus = GPUStatus.untried
    private var statuses: [EnhanceUpscalerKind: RungStatus] = [:]
    private var rungs: [EnhanceUpscalerKind: any ScalerRung] = [:]
    private var rungGeneration = 0
    private var governor = EnhanceGovernor()
    private var chain: Chain?
    /// The newest options set, and the ones the chain works from, which can lag a few frames behind during a drag.
    private var requested: EnhanceOptions
    private var applied: EnhanceOptions
    private var coalescer = OptionsCoalescer()
    private var flushTask: Task<Void, Never>?
    /// The last `enhance-rungs` line, so the same explanation is not written twice.
    private var lastRungLine = ""
    /// How the video track says its frames are shown (turned, mirrored), read from the asset when an item is attached.
    /// Frames are not drawn until it is known.
    private var trackOrientation = TrackOrientation.loading
    /// The last picture description and refusal that were logged, so a steady picture is written once.
    private var lastPictureLine = ""

    /// Frames from before a change that makes them wrong (a seek, a new item, stepping aside) are dropped, not shown.
    private var epoch = 0
    private var inFlight = 0
    private var sequence = 0
    private var frameCounter: UInt32 = 0
    private var showing = false
    private var consecutiveFailures = 0
    private var loggedOffered = 0
    private(set) var statistics = EnhanceStatistics()

    private static let maxInFlight = 2
    private static let displayBuffers = 6
    private static let idleAfter = 0.5
    private static let performanceEvery = 120

    /// - Parameters:
    ///   - options: What to do to the picture; everything off by default.
    ///   - logger: Where the `enhance-*` diagnostics go.
    ///   - power: Reports the device's thermal and Low Power Mode state. The default reads the system's; pass your own
    ///     to feed in more, such as the battery level.
    public init(options: EnhanceOptions = .off, logger: EngineLogger = .silent, power: (@MainActor () -> HardwareCapabilities.Power)? = nil) {
        layer = AVSampleBufferDisplayLayer()
        requested = options
        applied = options
        self.logger = logger
        if let power {
            self.power = power
        } else {
            self.power = { PictureEnhancer.systemPower() }
        }
    }

    private nonisolated static func systemPower() -> HardwareCapabilities.Power {
        let info = ProcessInfo.processInfo
        return HardwareCapabilities.Power(thermal: HardwareCapabilities.Thermal(info.thermalState), lowPowerMode: info.isLowPowerModeEnabled)
    }

    // MARK: Public controls

    /// The states the chain goes through, starting with the current one. Ends when the stream is no longer read.
    public func updates() -> AsyncStream<EnhanceState> {
        let made = AsyncStream<EnhanceState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        listeners[id] = made.continuation
        made.continuation.yield(state)
        made.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.listeners[id] = nil }
        }
        return made.stream
    }

    /// Starts enhancing the video of this item. It replaces any item attached before.
    public func attach(to item: AVPlayerItem) {
        detach()
        self.item = item
        loadTrackOrientation(of: item)
        startLink()
        ensureGPU()
        evaluate()
    }

    /// Lets go of the item and the GPU work; the player's picture shows. Call it before you release the enhancer.
    public func detach() {
        removeOutput()
        stopLink()
        item = nil
        trackOrientation = .loading
        lastPictureLine = ""
        resetSource()
        hideOutput()
        if let gpu { CVMetalTextureCacheFlush(gpu.cache, 0) }
        state = .idle
    }

    /// Pauses (false) or resumes (true) the chain. Call it when playback pauses or the app goes to the background and
    /// again when it comes back; while it is false the player's frames are not taken and the player's picture shows.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        link?.isPaused = !active
        if active {
            governor.reset()
            lastFrameTime = CACurrentMediaTime()
        } else {
            removeOutput()
            epoch += 1
            hideOutput()
        }
        evaluate()
    }

    // MARK: The decision

    /// Works out what to do from everything known now, and does it: the state, whether the player's frames are taken,
    /// whether the player's picture shows, and which scaler to get ready.
    @discardableResult
    private func evaluate() -> EnhanceDecision {
        guard item != nil, isActive else {
            stopShowing()
            state = .idle
            return .idle
        }
        let target = targetSize()
        if !Self.similar(target, knownTarget) {
            knownTarget = target
            invalidateRungs()
        }
        let context = EnhanceContext(
            options: applied, source: source, target: knownTarget, hasGPU: gpuStatus != .failed,
            shedPower: power().shouldShedOptionalWork, overloaded: governor.isPaused, statuses: statuses,
            ceiling: governor.ceiling
        )
        var decision = EnhanceMath.decide(context)
        // Until the GPU is set up the plain picture shows and the player's frames are left alone: frames that cannot be
        // drawn yet must not count against the chain.
        if case .run = decision, gpuStatus != .ready { decision = .idle }
        var running = false
        switch decision {
        case .idle: state = .idle
        case .unavailable(let reason): state = .unavailable(reason)
        case .paused(let reason): state = .paused(reason)
        case .run(let plan):
            state = .running(plan)
            running = true
        }
        if !running { stopShowing() }
        if wantsOutput(decision, context) {
            addOutput()
        } else {
            removeOutput()
            setLiveRate(false)
        }
        prepareRung(decision, context)
        return decision
    }

    /// The player's frames are needed to run the chain, and to learn what the picture is before any frame has come.
    private func wantsOutput(_ decision: EnhanceDecision, _ context: EnhanceContext) -> Bool {
        guard context.options.isEnabled else { return false }
        switch decision {
        case .run: return true
        case .paused, .unavailable: return false
        case .idle: return context.source == nil
        }
    }

    /// Starts the next scaler that is worth getting ready, if the picture needs one.
    private func prepareRung(_ decision: EnhanceDecision, _ context: EnhanceContext) {
        switch decision {
        case .unavailable, .paused: return
        case .idle, .run: break
        }
        guard gpuStatus == .ready, context.options.upscaler != .off, let picture = context.source else { return }
        let needed = EnhanceMath.fitScale(source: picture, target: context.target)
        guard needed >= EnhanceMath.minimumUpscaleRatio else { return }
        let ladder = EnhanceLadder.rungs(for: context.options.upscaler)
        guard let kind = EnhanceLadder.nextToPrepare(ladder, statuses: statuses, ceiling: context.ceiling) else {
            logRungs(ladder, ceiling: context.ceiling)
            return
        }
        prepare(kind, needed: needed, source: picture.size)
    }

    private func targetSize() -> PixelSize {
        var size = displaySize
        if size.width <= 0 || size.height <= 0 {
            let scale = layer.contentsScale
            size = CGSize(width: layer.bounds.width * scale, height: layer.bounds.height * scale)
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return PixelSize(width: 0, height: 0)
        }
        return PixelSize(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    /// A display that moved by a few percent (a rotation animation, a resize drag) is not worth new scalers.
    private static func similar(_ lhs: PixelSize, _ rhs: PixelSize) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return lhs == rhs }
        let across = abs(Double(lhs.width - rhs.width)) / Double(rhs.width)
        let down = abs(Double(lhs.height - rhs.height)) / Double(rhs.height)
        return across < 0.08 && down < 0.08
    }

    private func resetSource() {
        source = nil
        lastDisplaySeconds = nil
        invalidateRungs()
        governor.reset()
        consecutiveFailures = 0
        epoch += 1
    }

    private func invalidateRungs() {
        rungGeneration += 1
        statuses = [:]
        rungs = [:]
        chain = nil
        governor.restartCount()
        lastRungLine = ""
    }

    // MARK: The display link and the player's frames

    private func startLink() {
        guard link == nil else { return }
        let target = LinkTarget()
        target.owner = self
        let made = CADisplayLink(target: target, selector: #selector(LinkTarget.fire(_:)))
        made.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
        made.isPaused = !isActive
        made.add(to: .main, forMode: .common)
        link = made
        linkTarget = target
        isLive = true
        lastFrameTime = CACurrentMediaTime()
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        linkTarget = nil
    }

    /// Ticks at the video's pace while frames come, and a couple of times a second when they do not.
    private func setLiveRate(_ live: Bool) {
        guard let link, live != isLive else { return }
        isLive = live
        if live {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 60)
        } else {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 4, preferred: 2)
        }
    }

    private func addOutput() {
        guard output == nil, let item else { return }
        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: ScalerFormat.nv12VideoRange.code,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ]
        let made = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(made)
        output = made
        lastFrameTime = CACurrentMediaTime()
        setLiveRate(true)
    }

    private func removeOutput() {
        guard let output else { return }
        item?.remove(output)
        self.output = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard item != nil, isActive else { return }
        let now = CACurrentMediaTime()
        if governor.resume(now: now) {
            logger.measurement("enhance-resume", [("after", "cooldown")])
            evaluate()
        }
        if coalescer.pending != nil { flushOptions() }
        guard let output else {
            evaluate()
            return
        }
        guard let frame = pull(output, hostTime: link.targetTimestamp) else {
            if now - lastFrameTime > Self.idleAfter { setLiveRate(false) }
            return
        }
        lastFrameTime = now
        setLiveRate(true)
        handle(frame, tickTime: now, deadline: link.targetTimestamp + 2 * link.duration)
    }

    // MARK: Options changes

    /// Puts new options to work. Only a change of scaler setting, or the chain turning on or off, starts the ladder
    /// over; a change of strength leaves the scaler, its buffers and the governor's record as they are.
    private func apply(_ new: EnhanceOptions) {
        let change = new.change(from: applied)
        applied = new
        if change == .structural { governor.reset() }
        evaluate()
    }

    /// Applies held-back options once their interval is over.
    private func flushOptions() {
        if let due = coalescer.due(current: applied, now: CACurrentMediaTime()) {
            apply(due)
        } else {
            scheduleFlush()
        }
    }

    /// Makes sure held-back options are applied even when no frame comes, such as while paused.
    private func scheduleFlush() {
        guard flushTask == nil, let delay = coalescer.delay(now: CACurrentMediaTime()) else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            flushTask = nil
            flushOptions()
        }
    }

    private func pull(_ output: AVPlayerItemVideoOutput, hostTime: CFTimeInterval) -> PulledFrame? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        let pulled = output.pixelBufferAndDisplayTime(forItemTime: itemTime)
        guard let readOnly = pulled.pixelBuffer else { return nil }
        var pulledBuffer: CVPixelBuffer?
        readOnly.withUnsafeBuffer { pulledBuffer = $0 }
        guard let buffer = pulledBuffer else { return nil }
        return PulledFrame(readOnly: readOnly, buffer: buffer, time: pulled.itemTimeForDisplay)
    }

    // MARK: One frame

    /// What the chain does with one frame from the player: learn what the picture is, decide, and draw it.
    func handle(_ frame: PulledFrame, tickTime: CFTimeInterval, deadline: CFTimeInterval) {
        // The track's orientation is read once per item, in a moment; until it is known the frames cannot be drawn upright.
        guard trackOrientation != .loading else { return }
        let facts = FrameFacts(buffer: frame.buffer, presentationSize: item?.presentationSize ?? .zero, track: trackOrientation)
        logPicture(facts)
        if source?.size != facts.picture.size {
            invalidateRungs()
            epoch += 1
        }
        source = facts.picture
        noteTime(frame.time)
        guard case .run(let plan) = evaluate() else { return }
        render(frame, facts: facts, plan: plan, deadline: deadline)
    }

    /// Reads how the video track is turned, off the main thread's critical path: the asset loads it when it can. A track
    /// that cannot be read is taken as upright; the player's own shown size still catches a clip it turns.
    private func loadTrackOrientation(of item: AVPlayerItem) {
        trackOrientation = .loading
        Task { [weak self] in
            var found = TrackOrientation.known(.upright)
            do {
                if let track = try await item.asset.loadTracks(withMediaType: .video).first {
                    found = TrackOrientation(transform: try await track.load(.preferredTransform))
                }
            } catch {
                found = .known(.upright)
            }
            guard let self, self.item === item, self.trackOrientation == .loading else { return }
            self.setTrackOrientation(found)
        }
    }

    /// Takes the track's orientation as read; the picture is learned afresh from the next frame.
    func setTrackOrientation(_ orientation: TrackOrientation) {
        guard orientation != trackOrientation else { return }
        trackOrientation = orientation
        source = nil
        invalidateRungs()
        epoch += 1
        evaluate()
    }

    /// Says what the chain makes of the picture (its size, crop, turn and pixel shape), or why it cannot draw it.
    private func logPicture(_ facts: FrameFacts) {
        var fields: [(String, String)]
        if let reason = facts.picture.refusal {
            fields = [("result", "unsupported"), ("reason", reason)]
        } else if let geometry = facts.geometry {
            fields = [("result", "ok"), ("coded", geometry.coded.description), ("shown", geometry.size.description)]
            if geometry.crop.width != geometry.coded.width || geometry.crop.height != geometry.coded.height {
                fields.append(("crop", "\(geometry.crop.width)x\(geometry.crop.height)+\(geometry.crop.x)+\(geometry.crop.y)"))
            }
            fields.append(("turn", geometry.orientation.description))
            if abs(geometry.pixelAspect - 1) > 0.001 { fields.append(("pixel-aspect", String(format: "%.3f", geometry.pixelAspect))) }
        } else {
            return
        }
        let line = fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        guard line != lastPictureLine else { return }
        lastPictureLine = line
        logger.measurement("enhance-picture", fields)
    }

    /// A jump in the video's time is a seek: frames still on their way belong to the old position.
    private func noteTime(_ time: CMTime) {
        guard time.isValid else { return }
        let seconds = time.seconds
        if let last = lastDisplaySeconds, abs(seconds - last) > 1 {
            epoch += 1
            sequence += 2
            hideOutput()
        }
        lastDisplaySeconds = seconds
    }

    private func render(_ frame: PulledFrame, facts: FrameFacts, plan: EnhancePlan, deadline: CFTimeInterval) {
        guard let gpu else { return }
        statistics.offered += 1
        sequence += 1
        let ladder = EnhanceLadder.rungs(for: applied.upscaler)
        var rank: Int?
        if let kind = plan.upscaler { rank = ladder.firstIndex(of: kind) }
        guard inFlight < Self.maxInFlight else {
            skipFrame(rank: rank)
            return
        }
        var rung: (any ScalerRung)?
        if let kind = plan.upscaler {
            rung = rungs[kind]
            if rung == nil {
                skipFrame(rank: rank)
                return
            }
        }
        guard let made = ensureChain(for: plan, gpu: gpu) else {
            fail("no memory for the output buffers", rung: nil)
            return
        }
        var sourceStore: (any SurfaceSource)? = made.plain
        if let rung { sourceStore = rung.sources }
        guard let display = made.display.next(), let displayBuffer = display.buffer,
              let sourceSurface = sourceStore?.next()
        else {
            skipFrame(rank: rank)
            return
        }
        var scaledSurface: Surface?
        if let rung {
            scaledSurface = rung.scaled.next()
            if scaledSurface == nil {
                skipFrame(rank: rank)
                return
            }
        }
        guard let luma = EnhanceTextures.wrap(frame.buffer, plane: 0, format: .r8Unorm, cache: gpu.cache, usage: .shaderRead),
              let chroma = EnhanceTextures.wrap(frame.buffer, plane: 1, format: .rg8Unorm, cache: gpu.cache, usage: .shaderRead),
              let commands = gpu.queue.makeCommandBuffer()
        else {
            fail("Metal would not wrap the player's frame", rung: nil)
            return
        }
        let time = frame.time.isValid ? frame.time : CMTime(value: Int64(sequence), timescale: 60)
        do {
            let geometry = facts.geometry.map(IngestGeometry.init) ?? .identity
            let player = PlayerPicture(
                luma: luma.texture, chroma: chroma.texture, matrix: facts.matrix, fullRange: facts.fullRange, geometry: geometry
            )
            var composeInput = sourceSurface.texture
            if let rung, let scaledSurface {
                let rungFrame = RungFrame(gpu: gpu, player: player, source: sourceSurface, scaled: scaledSurface, time: time, sequence: sequence)
                composeInput = try rung.encode(rungFrame, into: commands)
            } else {
                try gpu.ingest(
                    player.coefficients, geometry: geometry, luma: player.luma, chroma: player.chroma, output: sourceSurface.texture,
                    commands: commands
                )
            }
            try gpu.compose(composeParameters(for: plan), input: composeInput, output: display.texture, commands: commands)
        } catch {
            fail("\(error)", rung: plan.upscaler)
            return
        }
        Self.copyTags(from: frame.buffer, to: displayBuffer, swapsAxes: facts.geometry?.orientation.swapsAxes ?? false)
        let lease = FrameLease(display: displayBuffer, epoch: epoch, deadline: deadline, rank: rank, kind: plan.upscaler)
        lease.keep = [frame.readOnly as Any, frame.buffer, luma.holder, chroma.holder, display, sourceSurface, scaledSurface as Any, rung as Any]
        commands.addCompletedHandler { [weak self] finishedCommands in
            let completed = finishedCommands.status == .completed
            let message = finishedCommands.error?.localizedDescription
            let gpuSeconds = max(finishedCommands.gpuEndTime - finishedCommands.gpuStartTime, 0)
            let finishedAt = CACurrentMediaTime()
            Task { @MainActor in
                self?.finished(lease, completed: completed, message: message, gpuSeconds: gpuSeconds, at: finishedAt)
            }
        }
        commands.commit()
        inFlight += 1
    }

    private func composeParameters(for plan: EnhancePlan) -> ComposeParameters {
        let scale = Double(plan.outputWidth) / Double(max(plan.sourceWidth, 1))
        frameCounter &+= 1
        return ComposeParameters(
            sharpen: Float(plan.sharpen), deband: Float(plan.deband),
            debandRadius: EnhanceMath.debandRadius(plan.deband, scale: scale),
            debandThreshold: EnhanceMath.debandThreshold(plan.deband), frame: frameCounter
        )
    }

    private func ensureChain(for plan: EnhancePlan, gpu: EnhanceGPU) -> Chain? {
        let source = PixelSize(width: plan.sourceWidth, height: plan.sourceHeight)
        let output = PixelSize(width: plan.outputWidth, height: plan.outputHeight)
        let key = ChainKey(source: source, output: output, upscaler: plan.upscaler)
        if let chain, chain.key == key { return chain }
        guard let display = PooledSurfaces(
            size: output, usage: [.shaderRead, .shaderWrite], minimum: 2, ceiling: Self.displayBuffers, cache: gpu.cache
        ) else { return nil }
        var plain: PrivateSurfaces?
        if plan.upscaler == nil {
            plain = PrivateSurfaces(device: gpu.device, size: source)
            if plain == nil { return nil }
        }
        // Textures of buffers nobody holds any more are let go; the ones in flight stay valid.
        CVMetalTextureCacheFlush(gpu.cache, 0)
        let made = Chain(key: key, display: display, plain: plain)
        chain = made
        return made
    }

    /// The display layer reads colour from the buffer's tags: carry the primaries, the transfer function and the pixel
    /// shape over from the player's frame. The YCbCr matrix stays behind, because the ingest has turned it into RGB.
    /// A picture turned by a quarter turn has its pixel shape turned with it.
    private static func copyTags(from source: CVPixelBuffer, to target: CVPixelBuffer, swapsAxes: Bool) {
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(target, key, value, .shouldPropagate)
            }
        }
        guard let shape = CVBufferCopyAttachment(source, kCVImageBufferPixelAspectRatioKey, nil) else { return }
        var carried: CFTypeRef = shape
        if swapsAxes, let dictionary = shape as? [String: Any],
           let horizontal = dictionary[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String],
           let vertical = dictionary[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] {
            let turned: [String: Any] = [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: vertical,
                kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: horizontal,
            ]
            carried = turned as CFDictionary
        }
        CVBufferSetAttachment(target, kCVImageBufferPixelAspectRatioKey, carried, .shouldPropagate)
    }

    // MARK: When the GPU is done

    private func finished(_ lease: FrameLease, completed: Bool, message: String?, gpuSeconds: Double, at time: CFTimeInterval) {
        inFlight -= 1
        guard lease.epoch == epoch else { return }
        let late = time > lease.deadline
        if completed {
            consecutiveFailures = 0
            statistics.gpuSeconds += gpuSeconds
            statistics.gpuMaxSeconds = max(statistics.gpuMaxSeconds, gpuSeconds)
            show(lease.display)
            statistics.shown += 1
            if late { statistics.late += 1 }
        } else {
            fail(message ?? "the GPU reported an error", rung: lease.kind)
        }
        record(missed: late || !completed, rank: lease.rank)
        logPerformanceIfDue()
    }

    private func show(_ buffer: CVPixelBuffer) {
        var described: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &described
        )
        guard status == noErr, let format = described else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid
        )
        var created: CMSampleBuffer?
        let made = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &created
        )
        guard made == noErr, let sample = created else { return }
        // Show it now: the frame was pulled for this moment, and the player keeps the sound in step.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                entry, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        layer.sampleBufferRenderer.enqueue(sample)
        showing = true
    }

    /// Takes the enhanced picture off the layer so the player's shows.
    private func hideOutput() {
        guard showing else { return }
        showing = false
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    private func stopShowing() {
        if showing || inFlight > 0 { epoch += 1 }
        hideOutput()
    }

    private func skipFrame(rank: Int?) {
        statistics.skipped += 1
        record(missed: true, rank: rank)
    }

    /// A frame the chain could not deliver on time counts against it; too many make it step down and then aside.
    private func record(missed: Bool, rank: Int?) {
        let ladder = EnhanceLadder.rungs(for: applied.upscaler)
        let action = governor.record(missed: missed, rank: rank, lowestRank: max(ladder.count - 1, 0), now: CACurrentMediaTime())
        switch action {
        case .none:
            return
        case .demote:
            var fields = [("ceiling", String(governor.ceiling))]
            if let rank, ladder.indices.contains(rank) {
                fields.append(("from", ladder[rank].rawValue))
                fields.append(("because", "about a quarter of recent frames were late or missed"))
            }
            if ladder.indices.contains(governor.ceiling) { fields.append(("to", ladder[governor.ceiling].rawValue)) }
            logger.measurement("enhance-demote", fields)
        case .pause(let until):
            let seconds = String(format: "%.0f", until - CACurrentMediaTime())
            logger.measurement("enhance-pause", [("reason", "dropped-frames"), ("seconds", seconds)])
        case .retire:
            logger.measurement("enhance-pause", [("reason", "dropped-frames"), ("final", "true")])
        }
        evaluate()
    }

    /// A scaler that fails is dropped and the next one down the ladder takes over; a failure with no scaler to blame
    /// three times running means the GPU cannot be used.
    private func fail(_ reason: String, rung kind: EnhanceUpscalerKind?) {
        statistics.failed += 1
        logger.measurement("enhance-error", [("rung", kind?.rawValue ?? "none"), ("reason", reason)])
        if let kind {
            statuses[kind] = .failed(reason)
            rungs[kind] = nil
            governor.restartCount()
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 { gpuStatus = .failed }
        }
        evaluate()
    }

    // MARK: Getting the GPU and the scalers ready, off the main thread

    private func ensureGPU() {
        guard gpuStatus == .untried else { return }
        gpuStatus = .preparing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = DispatchTime.now()
            let outcome = Unchecked(Self.buildGPU())
            let elapsed = seconds(since: started)
            Task { @MainActor in
                self?.gpuFinished(outcome.value, seconds: elapsed)
            }
        }
    }

    private nonisolated static func buildGPU() -> GPUOutcome {
        do {
            return .ready(try EnhanceGPU())
        } catch {
            return .failed("\(error)")
        }
    }

    private func gpuFinished(_ outcome: GPUOutcome, seconds: TimeInterval) {
        let milliseconds = String(format: "%.0f", seconds * 1000)
        switch outcome {
        case .ready(let made):
            gpu = made
            gpuStatus = .ready
            logger.measurement("enhance-gpu", [("result", "ready"), ("device", made.device.name), ("ms", milliseconds)])
        case .failed(let reason):
            gpuStatus = .failed
            logger.measurement("enhance-gpu", [("result", "failed"), ("reason", reason), ("ms", milliseconds)])
        }
        evaluate()
    }

    private func prepare(_ kind: EnhanceUpscalerKind, needed: Double, source: PixelSize) {
        guard let gpu else { return }
        statuses[kind] = .preparing
        let request = RungRequest(kind: kind, gpu: gpu, source: source, needed: needed)
        let generation = rungGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = DispatchTime.now()
            let outcome = Unchecked(Self.buildRung(request))
            let elapsed = seconds(since: started)
            Task { @MainActor in
                self?.rungFinished(kind, generation: generation, outcome: outcome.value, seconds: elapsed)
            }
        }
    }

    private nonisolated static func buildRung(_ request: RungRequest) -> RungOutcome {
        do {
            return .ready(try EnhanceRungs.make(request))
        } catch let skip as EnhanceSkip {
            return .skipped(skip.description)
        } catch {
            return .failed("\(error)")
        }
    }

    private func rungFinished(_ kind: EnhanceUpscalerKind, generation: Int, outcome: RungOutcome, seconds: TimeInterval) {
        guard generation == rungGeneration else { return }
        var fields: [(String, String)] = [("rung", kind.rawValue), ("ms", String(format: "%.0f", seconds * 1000))]
        switch outcome {
        case .ready(let rung):
            rungs[kind] = rung
            statuses[kind] = .ready(rung.output)
            fields.append(("result", "ready"))
            fields.append(("out", rung.output.description))
            fields.append(contentsOf: rung.notes)
        case .failed(let reason):
            statuses[kind] = .failed(reason)
            fields.append(("result", "failed"))
            fields.append(("reason", reason))
        case .skipped(let reason):
            statuses[kind] = .skipped(reason)
            fields.append(("result", "skipped"))
            fields.append(("reason", reason))
        }
        logger.measurement("enhance-probe", fields)
        governor.restartCount()
        evaluate()
    }

    /// Says why each rung is or is not in use, once every rung that could change the choice has an answer. Written again
    /// only when the explanation changes: after a demotion, a failure on a frame or a new picture size.
    private func logRungs(_ ladder: [EnhanceUpscalerKind], ceiling: Int) {
        guard EnhanceLadder.isSettled(ladder, statuses: statuses, ceiling: ceiling) else { return }
        var fields = EnhanceLadder.explain(ladder, statuses: statuses, ceiling: ceiling).map { ($0.kind.rawValue, $0.text) }
        let chosen = EnhanceLadder.active(ladder, statuses: statuses, ceiling: ceiling)
        fields.append(("chosen", chosen?.kind.rawValue ?? "none"))
        let line = fields.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
        guard line != lastRungLine else { return }
        lastRungLine = line
        logger.measurement("enhance-rungs", fields)
    }

    // MARK: Diagnostics

    private func logPlan() {
        let fields: [(String, String)]
        switch state {
        case .idle:
            fields = [("state", "idle")]
        case .running(let plan):
            fields = [
                ("state", "running"), ("scaler", plan.upscaler?.rawValue ?? "none"),
                ("source", "\(plan.sourceWidth)x\(plan.sourceHeight)"), ("out", "\(plan.outputWidth)x\(plan.outputHeight)"),
                ("sharpen", String(plan.sharpen)), ("deband", String(plan.deband)),
            ]
        case .paused(let reason):
            fields = [("state", "paused"), ("reason", reason.rawValue)]
        case .unavailable(let reason):
            fields = [("state", "unavailable"), ("reason", reason.rawValue)]
        }
        logger.measurement("enhance-plan", fields)
    }

    private func logPerformanceIfDue() {
        guard statistics.offered - loggedOffered >= Self.performanceEvery else { return }
        loggedOffered = statistics.offered
        let shown = Double(max(statistics.shown, 1))
        let average = String(format: "%.1f", statistics.gpuSeconds / shown * 1000)
        let slowest = String(format: "%.1f", statistics.gpuMaxSeconds * 1000)
        logger.measurement("enhance-perf", [
            ("frames", String(statistics.offered)), ("shown", String(statistics.shown)), ("late", String(statistics.late)),
            ("skipped", String(statistics.skipped)), ("failed", String(statistics.failed)),
            ("gpu-ms-avg", average), ("gpu-ms-max", slowest),
        ])
    }
}
