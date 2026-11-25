import Foundation

// The decisions behind the picture enhancer, kept free of Metal and AVFoundation so they can be tested anywhere.

/// Whole pixels, as video and displays count them.
struct PixelSize: Sendable, Hashable, CustomStringConvertible {
    var width: Int
    var height: Int

    var pixels: Int { width * height }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var description: String { "\(width)x\(height)" }
}

/// Whether a picture is standard dynamic range, the only kind the chain enhances.
enum PictureRange: Sendable, Equatable {
    case sdr, hdr
}

/// What a frame says about the picture, as far as planning goes.
struct SourcePicture: Sendable, Equatable {
    /// The upright picture's size: what the chain works on, after the crop and the turn.
    var size: PixelSize
    /// Width of one pixel over its height, for the upright picture: 1 for square pixels.
    var pixelAspect = 1.0
    var range = PictureRange.sdr
    /// Why the chain cannot draw this picture, in words for a log line; nil when it can. A crop, a turn, an odd size or a
    /// non-square pixel are all handled, so this is for what truly cannot be: a pixel format that is not 8-bit 4:2:0,
    /// a track transform that is not a turn, a frame smaller than 2x2.
    var refusal: String?
}

enum EnhanceMath {
    /// An upscale smaller than this is not worth a pass: the scaler is skipped.
    static let minimumUpscaleRatio = 1.1
    /// A bigger scale is left to the display's own scaler.
    static let maximumScale = 4.0
    /// The most pixels one output picture may have: 2560x1440, 14.7 MB a buffer. Bounds the chain's memory.
    static let maximumOutputPixels = 2560 * 1440
    /// The most pixels a fixed-factor machine-learning scaler may make in one frame for a small picture (720p class or
    /// smaller), before the chain scales the result down to the display: a little over 4x of 854x480 (6.6 MP) and of
    /// 768x576 (7.1 MP), well under 4x of 720p (14.7 MP). Every other picture is held to `maximumOutputPixels`.
    static let maximumModelPixels = 7_500_000
    /// How much smaller than the scaler's result the picture it hands on may be: a 4x result is scaled down to 2x at
    /// most. More than that is a model run mostly thrown away, so that factor is left out.
    static let maximumDownscale = 2.0

    /// A picture of 720p class or smaller: its longer side is at most 1280 and its shorter side at most 720 (a portrait
    /// clip counts the same as its landscape twin). The best scaler is preferred for these.
    static func isSmallPicture(_ size: PixelSize) -> Bool {
        max(size.width, size.height) <= 1280 && min(size.width, size.height) <= 720
    }

    /// The most pixels a fixed-factor scaler may produce for this picture.
    static func modelBudget(for source: PixelSize) -> Int {
        isSmallPicture(source) ? maximumModelPixels : maximumOutputPixels
    }

    /// The largest scale whose picture stays inside `maximumOutputPixels`.
    static func outputBudgetScale(_ source: PixelSize) -> Double {
        guard !source.isEmpty else { return 1 }
        return (Double(maximumOutputPixels) / Double(source.pixels)).squareRoot()
    }

    /// The picture a fixed-factor scaler makes of `source` at `factor`: its size in pixels.
    static func modelPixels(_ source: PixelSize, _ factor: Double) -> Double {
        Double(source.pixels) * factor * factor
    }

    /// The size the chain carries on with after a fixed-factor scaler whose own result is `model`. A result inside
    /// `maximumOutputPixels` is used as it is; a bigger one (only a small picture may make one) is scaled down to the
    /// display's need, held to the output budget.
    static func rungOutput(model: PixelSize, source: PixelSize, needed: Double) -> PixelSize {
        guard model.pixels > maximumOutputPixels else { return model }
        return scaled(source, by: min(max(needed, 1), maximumScale, outputBudgetScale(source)))
    }

    /// Why this picture gets the ladder it does, for the `enhance-rungs` line.
    static func ladderPolicy(source: PixelSize) -> String {
        let model = String(format: "%.1f", Double(modelBudget(for: source)) / 1_000_000)
        if isSmallPicture(source) {
            return "\(source) is 720p class or smaller: the best scaler goes first, and a model run up to \(model) MP a frame is allowed before the result is scaled down to the display"
        }
        return "\(source) is above 720p class: a model run over \(model) MP a frame is too costly for live video"
    }

    /// The scale that makes the source, with its pixel shape, just fit the target (aspect fit).
    static func fitScale(source: SourcePicture, target: PixelSize) -> Double {
        guard !source.size.isEmpty, !target.isEmpty else { return 1 }
        let aspect = source.pixelAspect > 0 ? source.pixelAspect : 1
        return min(
            Double(target.width) / (Double(source.size.width) * aspect),
            Double(target.height) / Double(source.size.height)
        )
    }

    /// The output of a scaler that takes any size: the fit scale held to `maximumScale` and the pixel budget.
    /// Nil when what is left is not worth a pass.
    static func freeOutput(source: PixelSize, scale: Double) -> PixelSize? {
        guard !source.isEmpty else { return nil }
        let budget = (Double(maximumOutputPixels) / Double(source.pixels)).squareRoot()
        let limit = min(scale, maximumScale, budget)
        guard limit >= minimumUpscaleRatio else { return nil }
        return PixelSize(
            width: Int((Double(source.width) * limit).rounded()),
            height: Int((Double(source.height) * limit).rounded())
        )
    }

    /// The factor a fixed-factor scaler runs at: of those that `fits`, the one nearest the needed scale as a
    /// ratio, the smaller on a tie. A factor whose result is over the picture's `modelBudget` never qualifies. A result
    /// over `maximumOutputPixels` (only a small picture may make one) qualifies when scaling it down to what the
    /// display needs is at most `maximumDownscale`. The display's own scaler covers the rest of the difference.
    static func factor(needed: Double, source: PixelSize, from factors: [Double], fits: (Double) -> Bool = { _ in true }) -> Double? {
        let wanted = max(min(needed, maximumScale), 1)
        let candidates = factors.filter { factor in
            factor > 1 && fair(factor, source: source, wanted: wanted) && fits(factor)
        }
        return candidates.min { lhs, rhs in
            let left = abs(log(lhs / wanted)), right = abs(log(rhs / wanted))
            return left == right ? lhs < rhs : left < right
        }
    }

    private static func fair(_ factor: Double, source: PixelSize, wanted: Double) -> Bool {
        let made = modelPixels(source, factor)
        guard made <= Double(modelBudget(for: source)) else { return false }
        guard made > Double(maximumOutputPixels) else { return true }
        return factor / min(wanted, outputBudgetScale(source)) <= maximumDownscale
    }

    /// What a fixed-factor scaler does with a picture.
    enum FactorVerdict: Equatable {
        /// Run at this factor.
        case use(Double)
        /// Leave this scaler out, and why, in words for a probe line.
        case skip(String)
    }

    /// Picks the factor a fixed-factor scaler runs at, or says why it does not run. The factors are all the scaler
    /// offers for this picture: it cannot make any other size, so a factor whose result is over the picture's budget
    /// (`modelBudget(for:)`) is out, however good the picture it would make. Apple's quality super-resolution offers only
    /// 4x on the iPhone 17 Pro: 4x of 720p is 14.7 MP a frame, twice even the small-picture budget, a model run that is
    /// not credible at 24 to 30 frames a second on a phone, so that scaler is skipped with a plain reason and the
    /// ladder goes on to the next rung. 4x of a 480p-class picture (6.6 MP) is inside the small-picture budget and
    /// runs, and its result is then scaled down to the display (`rungOutput`).
    static func fixedFactor(
        needed: Double, source: PixelSize, from offered: [Double], fits: (Double) -> Bool = { _ in true }
    ) -> FactorVerdict {
        let upscales = offered.filter { $0 > 1 }
        guard let smallest = upscales.min() else {
            return .skip("it offers no scale factor above 1x for a \(source) picture (it offers \(factorList(offered)))")
        }
        if let chosen = factor(needed: needed, source: source, from: offered, fits: fits) { return .use(chosen) }
        let budget = Double(modelBudget(for: source))
        let affordable = upscales.filter { modelPixels(source, $0) <= budget }
        guard let cheapest = affordable.min() else {
            let which = upscales.count == 1 ? "only \(factorText(smallest))x" : "nothing under \(factorText(smallest))x"
            return .skip("\(which), too costly for live video")
        }
        if affordable.allSatisfy(fits) {
            let target = min(max(min(needed, maximumScale), 1), outputBudgetScale(source))
            return .skip(
                "\(factorText(cheapest))x fits the budget but is more than twice the \(String(format: "%.1f", target))x the display needs"
            )
        }
        return .skip("no scale factor fits a \(source) picture (it offers \(factorList(offered)))")
    }

    private static func factorList(_ factors: [Double]) -> String {
        "[" + factors.map { factorText($0) + "x" }.joined(separator: ", ") + "]"
    }

    /// 4 reads "4", 1.5 reads "1.5".
    static func factorText(_ factor: Double) -> String {
        factor == factor.rounded() ? String(Int(factor)) : String(factor)
    }

    /// The size a fixed factor makes of a source. Rounds to nearest.
    static func scaled(_ source: PixelSize, by factor: Double) -> PixelSize {
        PixelSize(width: Int((Double(source.width) * factor).rounded()), height: Int((Double(source.height) * factor).rounded()))
    }

    /// The most a pixel may differ from the average of its neighbours and still be smoothed, as a fraction of full scale.
    static func debandThreshold(_ strength: Double) -> Float {
        Float((1 + 11 * strength) / 255)
    }

    /// How far the deband pass looks, in output pixels: wider for stronger smoothing, and scaled with the picture.
    static func debandRadius(_ strength: Double, scale: Double) -> Float {
        Float((4 + 12 * strength) * max(1, scale))
    }

    // MARK: Denoise, deblock and vivid (v3.1.0)

    /// How different two pixels' colours may be, as a fraction of full scale, and still be averaged by the denoiser's
    /// spatial step: noise is smoothed, a real edge stays.
    static func denoiseRange(_ strength: Double) -> Float { Float((3 + 14 * strength) / 255) }

    /// How much of the spatial average goes into the picture.
    static func denoiseSpatialAmount(_ strength: Double) -> Float { Float(0.25 + 0.5 * strength) }

    /// The mean brightness change between frames, around a pixel, that still counts as noise rather than motion.
    static func denoiseTolerance(_ strength: Double) -> Float { Float((3 + 12 * strength) / 255) }

    /// The weight of the previous frame in a still area: 0.4 is a short memory, 0.9 about ten frames.
    static func denoiseHistoryWeight(_ strength: Double) -> Float { Float(0.4 + 0.5 * strength) }

    /// The largest step across a block edge that is softened, as a fraction of full scale: 3 to 20 codes of 255.
    static func deblockStep(_ strength: Double) -> Float { Float((3 + 17 * strength) / 255) }

    /// How busy the picture beside the edge may be and still be softened: 2 to 8 codes of 255.
    static func deblockActivity(_ strength: Double) -> Float { Float((2 + 6 * strength) / 255) }

    /// How much of the correction is applied: 0.4 at the faintest, all of it from half strength.
    static func deblockAmount(_ strength: Double) -> Float { Float(min(1, 0.4 + 1.2 * strength)) }

    /// How far the vivid pass looks for the local average, in output pixels.
    static func vividRadius(outputHeight: Int) -> Float { Float(max(4, Double(outputHeight) / 120)) }

    /// The size of the dither the final pass adds, in codes of 255: debanding needs it, and so do denoising and vivid,
    /// which smooth or stretch gradients that would otherwise step. Zero when none of them is on.
    static func ditherCodes(deband: Double, denoise: Double, vivid: Double) -> Float {
        var codes: Float = 0
        if deband > 0 { codes = Float(0.5 + 0.5 * deband) }
        if denoise > 0 { codes = max(codes, 0.75) }
        if vivid > 0 { codes = max(codes, 0.5) }
        return codes
    }
}

/// How well a scaler is doing on the current picture.
enum RungStatus: Sendable, Equatable {
    case untried, preparing
    /// Ready to scale, and the size of what it makes.
    case ready(PixelSize)
    /// This scaler will not run here, and why: something went wrong.
    case failed(String)
    /// This scaler was left out on purpose, and why: it works, but not for live video on this picture.
    case skipped(String)
}

/// A scaler picked to run now.
struct RungChoice: Sendable, Equatable {
    var kind: EnhanceUpscalerKind
    var output: PixelSize
    /// Position in the ladder: 0 is the best.
    var rank: Int
}

/// The scalers a setting can use, best first. The last is the floor that always works.
enum EnhanceLadder {
    static func rungs(for upscaler: EnhanceOptions.Upscaler) -> [EnhanceUpscalerKind] {
        switch upscaler {
        case .off: []
        case .automatic: [.videoToolboxSuperResolution, .videoToolboxLowLatency, .metalFXSpatial, .lanczos]
        case .lineArt: [.lineArt, .lanczos]
        }
    }

    /// The best rung that is ready and not above the ceiling.
    static func active(_ ladder: [EnhanceUpscalerKind], statuses: [EnhanceUpscalerKind: RungStatus], ceiling: Int) -> RungChoice? {
        for (rank, kind) in ladder.enumerated() where rank >= ceiling {
            if case .ready(let output)? = statuses[kind] { return RungChoice(kind: kind, output: output, rank: rank) }
        }
        return nil
    }

    /// The rung to start preparing, one at a time. The floor goes first so a picture shows at once; then the better
    /// rungs, best first, until the one in use. Rungs below the one in use are never prepared.
    static func nextToPrepare(_ ladder: [EnhanceUpscalerKind], statuses: [EnhanceUpscalerKind: RungStatus], ceiling: Int) -> EnhanceUpscalerKind? {
        guard let floor = ladder.last, !statuses.values.contains(.preparing) else { return nil }
        if (statuses[floor] ?? .untried) == .untried { return floor }
        let inUse = active(ladder, statuses: statuses, ceiling: ceiling)?.rank ?? ladder.count
        for (rank, kind) in ladder.enumerated() where rank >= ceiling && rank < inUse {
            if (statuses[kind] ?? .untried) == .untried { return kind }
        }
        return nil
    }

    /// Why each rung is or is not the one in use, best first, for the diagnostics. `ceiling` is the rank the governor
    /// has demoted the chain to.
    /// `smallPicture` says the picture is 720p class or smaller, which gets the best scaler first.
    static func explain(
        _ ladder: [EnhanceUpscalerKind], statuses: [EnhanceUpscalerKind: RungStatus], ceiling: Int, smallPicture: Bool = false
    ) -> [RungReason] {
        let chosen = active(ladder, statuses: statuses, ceiling: ceiling)
        return ladder.enumerated().map { rank, kind in
            let status = statuses[kind] ?? .untried
            let text: String
            switch status {
            case .failed(let reason): text = "failed: \(reason)"
            case .skipped(let reason): text = "skipped: \(reason)"
            default:
                if rank < ceiling {
                    if case .ready = status {
                        text = "demoted: it dropped frames"
                    } else {
                        text = "not tried: the chain was demoted below it"
                    }
                } else if chosen?.kind == kind {
                    text = smallPicture && rank == 0 ? "chosen: the best scaler, which a small picture gets first" : "chosen"
                } else if let chosen, chosen.rank < rank {
                    text = status == .untried ? "not tried: a better rung is in use" : "not needed: a better rung is in use"
                } else if status == .preparing {
                    text = "preparing"
                } else if case .ready = status {
                    text = "ready"
                } else {
                    text = "not tried yet"
                }
            }
            return RungReason(kind: kind, text: text)
        }
    }

    /// True when every rung that could still change the choice has an answer.
    static func isSettled(_ ladder: [EnhanceUpscalerKind], statuses: [EnhanceUpscalerKind: RungStatus], ceiling: Int) -> Bool {
        !statuses.values.contains(.preparing) && nextToPrepare(ladder, statuses: statuses, ceiling: ceiling) == nil
    }
}

/// One line of the ladder's explanation: a rung and why it is or is not in use.
struct RungReason: Equatable {
    var kind: EnhanceUpscalerKind
    var text: String
}

/// Everything the plan depends on.
struct EnhanceContext: Equatable {
    var options: EnhanceOptions
    /// Nil until the first frame arrives.
    var source: SourcePicture?
    /// The pixels the picture fits into on screen; empty when unknown.
    var target: PixelSize
    var hasGPU = true
    var shedPower = false
    var overloaded = false
    var statuses: [EnhanceUpscalerKind: RungStatus] = [:]
    var ceiling = 0
}

enum EnhanceDecision: Equatable {
    case idle
    case unavailable(EnhanceUnavailableReason)
    case paused(EnhancePauseReason)
    case run(EnhancePlan)
}

extension EnhanceMath {
    /// What to do now. The gates come first and each one hands the picture back to the player: nothing asked for,
    /// no frame yet, no GPU, HDR, a picture the chain cannot take, a device that needs to save power, a chain that
    /// could not keep up. Then the stages: the upscaler only when the source is smaller than the display, and
    /// only when a scaler is ready.
    static func decide(_ context: EnhanceContext) -> EnhanceDecision {
        let options = context.options
        guard options.isEnabled, let source = context.source, !source.size.isEmpty else { return .idle }
        guard context.hasGPU else { return .unavailable(.noGPU) }
        if source.range == .hdr { return .unavailable(.highDynamicRange) }
        if source.refusal != nil { return .unavailable(.unsupportedPicture) }
        if context.shedPower { return .paused(.powerSaving) }
        if context.overloaded { return .paused(.droppedFrames) }
        var scaler: RungChoice?
        if options.upscaler != .off, fitScale(source: source, target: context.target) >= minimumUpscaleRatio {
            scaler = EnhanceLadder.active(EnhanceLadder.rungs(for: options.upscaler), statuses: context.statuses, ceiling: context.ceiling)
        }
        let perPixel = options.sharpen > 0 || options.deband > 0 || options.denoise > 0 || options.deblock > 0 || options.vivid > 0
        guard scaler != nil || perPixel else { return .idle }
        let output = scaler?.output ?? source.size
        return .run(EnhancePlan(
            upscaler: scaler?.kind, sourceWidth: source.size.width, sourceHeight: source.size.height,
            outputWidth: output.width, outputHeight: output.height, sharpen: options.sharpen, deband: options.deband,
            denoise: options.denoise, deblock: options.deblock, vivid: options.vivid
        ))
    }
}

/// Counts how often the chain misses its frames over a sliding window.
struct DropMonitor: Sendable, Equatable {
    static let window = 30
    /// Missed frames in a full window that count as overload: about a quarter.
    static let threshold = 8
    private var ring = [Bool](repeating: false, count: DropMonitor.window)
    private var next = 0
    private(set) var recorded = 0
    private(set) var missed = 0

    mutating func record(missed isMissed: Bool) {
        if ring[next] { missed -= 1 }
        ring[next] = isMissed
        if isMissed { missed += 1 }
        next = (next + 1) % Self.window
        recorded = min(recorded + 1, Self.window)
    }

    var isOverloaded: Bool { recorded == Self.window && missed >= Self.threshold }
}

/// Decides when the chain steps down a rung or gives way to the plain picture, from how its frames are going.
/// A cheaper scaler is tried before the chain gives up; a pause ends by itself after a cooldown that doubles,
/// and a third pause is final until `reset()`.
struct EnhanceGovernor: Sendable, Equatable {
    enum Action: Equatable {
        case none
        /// Use a scaler below the one that was running.
        case demote
        /// Show the plain picture until this time.
        case pause(until: TimeInterval)
        /// Show the plain picture until `reset()`.
        case retire
    }

    /// Frames after a change that are not counted: the first ones carry setup cost.
    static let warmUpFrames = 10
    static let cooldowns: [TimeInterval] = [10, 20, 40]

    /// The ladder rank the chain may not rise above. 0 allows every rung.
    private(set) var ceiling = 0
    private(set) var strikes = 0
    private(set) var pausedUntil: TimeInterval?
    private(set) var retired = false
    private var monitor = DropMonitor()
    private var warmUp = EnhanceGovernor.warmUpFrames

    var isPaused: Bool { retired || pausedUntil != nil }

    /// Reports one offered frame. `rank` is the rung that drew it, nil when no scaler is in use, and `lowestRank`
    /// the last rung of the ladder.
    mutating func record(missed: Bool, rank: Int?, lowestRank: Int, now: TimeInterval) -> Action {
        guard !isPaused else { return .none }
        if warmUp > 0 {
            warmUp -= 1
            return .none
        }
        monitor.record(missed: missed)
        guard monitor.isOverloaded else { return .none }
        restartCount()
        if let rank, rank < lowestRank {
            ceiling = rank + 1
            return .demote
        }
        strikes += 1
        guard strikes <= Self.cooldowns.count else {
            retired = true
            return .retire
        }
        let until = now + Self.cooldowns[strikes - 1]
        pausedUntil = until
        return .pause(until: until)
    }

    /// True once, when a pause has run its course.
    mutating func resume(now: TimeInterval) -> Bool {
        guard let until = pausedUntil, now >= until else { return false }
        pausedUntil = nil
        restartCount()
        return true
    }

    /// Forgets the frames seen so far, for a change that makes them unrepresentative: a new rung, a new size.
    mutating func restartCount() {
        monitor = DropMonitor()
        warmUp = Self.warmUpFrames
    }

    /// Starts over with the whole ladder: new item, new scaler setting.
    mutating func reset() {
        self = EnhanceGovernor()
    }
}

/// The video's YCbCr matrix: the coefficients that turn luma and chroma back into red, green and blue.
enum YCbCrMatrix: Sendable, Equatable {
    case bt601, bt709, bt2020

    var kr: Float {
        switch self {
        case .bt601: 0.299
        case .bt709: 0.2126
        case .bt2020: 0.2627
        }
    }

    var kb: Float {
        switch self {
        case .bt601: 0.114
        case .bt709: 0.0722
        case .bt2020: 0.0593
        }
    }

    /// What an untagged picture of this size is assumed to use: HD is BT.709, smaller is BT.601. A picture shot upright on
    /// a phone is coded on its side, so the longer and the shorter side are judged, not the width and the height.
    static func assumed(for size: PixelSize) -> YCbCrMatrix {
        max(size.width, size.height) >= 1280 || min(size.width, size.height) >= 720 ? .bt709 : .bt601
    }
}

/// What the ingest kernel needs to turn one 8-bit NV12 sample into RGB, and a CPU copy of its arithmetic.
struct IngestCoefficients: Sendable, Equatable {
    var yOffset: Float
    var yScale: Float
    var cOffset: Float
    var cScale: Float
    var kr: Float
    var kb: Float

    init(matrix: YCbCrMatrix, fullRange: Bool) {
        // Video range puts black at 16 and white at 235 for luma, and the chroma span at 16...240; full range uses all 256 steps.
        yOffset = fullRange ? 0 : 16 / 255
        yScale = fullRange ? 1 : 255 / 219
        cOffset = 128 / 255
        cScale = fullRange ? 1 : 255 / 224
        kr = matrix.kr
        kb = matrix.kb
    }

    /// The kernel's arithmetic for one sample, each value in 0...1 as the texture reads it. Unclamped.
    func rgb(y: Float, cb: Float, cr: Float) -> (r: Float, g: Float, b: Float) {
        let luma = (y - yOffset) * yScale
        let blue = (cb - cOffset) * cScale
        let red = (cr - cOffset) * cScale
        let r = luma + 2 * (1 - kr) * red
        let b = luma + 2 * (1 - kb) * blue
        let g = (luma - kr * r - kb * b) / (1 - kr - kb)
        return (r, g, b)
    }
}

/// Lanczos-3 filter taps for stretching a line of `source` samples to `output` samples. Each output sample has the
/// first source sample it reads and six weights that sum to one; reads past either end repeat the edge sample.
/// Computed once per size on the CPU so the shader only multiplies.
struct LanczosTaps: Sendable, Equatable {
    static let count = 6
    private(set) var starts: [Int32] = []
    private(set) var weights: [Float] = []

    init(source: Int, output: Int) {
        let scale = Double(max(source, 1)) / Double(max(output, source, 1))
        starts.reserveCapacity(output)
        weights.reserveCapacity(output * Self.count)
        for index in 0..<max(output, 0) {
            let centre = (Double(index) + 0.5) * scale - 0.5
            let first = Int(centre.rounded(.down)) - 2
            let row = (0..<Self.count).map { Self.kernel(centre - Double(first + $0)) }
            let sum = row.reduce(0, +)
            starts.append(Int32(first))
            weights.append(contentsOf: row.map { Float($0 / sum) })
        }
    }

    static func kernel(_ x: Double) -> Double {
        let distance = abs(x)
        if distance < 1e-9 { return 1 }
        if distance >= 3 { return 0 }
        let angle = Double.pi * distance
        return 3 * sin(angle) * sin(angle / 3) / (angle * angle)
    }
}

/// Taps for scaling a line of `source` samples down to fewer, `output`. Lanczos-2 stretched by the ratio, so it
/// averages the samples that fall in each output sample instead of skipping them, with eight taps: enough for a ratio
/// up to 2 (`EnhanceMath.maximumDownscale`). Each output sample has the first source sample it reads and eight weights that
/// sum to one; reads past either end repeat the edge sample.
struct DownscaleTaps: Sendable, Equatable {
    static let count = 8
    private(set) var starts: [Int32] = []
    private(set) var weights: [Float] = []

    init(source: Int, output: Int) {
        let ratio = max(Double(max(source, 1)) / Double(max(output, 1)), 1)
        starts.reserveCapacity(max(output, 0))
        weights.reserveCapacity(max(output, 0) * Self.count)
        for index in 0..<max(output, 0) {
            let centre = (Double(index) + 0.5) * ratio - 0.5
            let first = Int(centre.rounded(.down)) - Self.count / 2 + 1
            let row = (0..<Self.count).map { Self.kernel((centre - Double(first + $0)) / ratio) }
            let sum = row.reduce(0, +)
            starts.append(Int32(first))
            weights.append(contentsOf: row.map { Float($0 / sum) })
        }
    }

    /// Lanczos with two lobes.
    static func kernel(_ x: Double) -> Double {
        let distance = abs(x)
        if distance < 1e-9 { return 1 }
        if distance >= 2 { return 0 }
        let angle = Double.pi * distance
        return 2 * sin(angle) * sin(angle / 2) / (angle * angle)
    }
}

/// Whether the denoiser's last result may be blended into the next frame. It may when it came from the frame just
/// before this one, in the same stretch of video: not after a seek, a new item, a size or scaler change or a pause
/// (the enhancer's `epoch` counts those), and not when the video's time went backwards or jumped.
struct DenoiseMemory: Sendable, Equatable {
    /// The longest gap between two frames that still counts as consecutive, in seconds.
    static let longestGap = 0.5

    private var epoch = -1
    private var lastTime: Double?
    private var filled = false

    func remembers(epoch current: Int, time: Double?) -> Bool {
        guard filled, epoch == current else { return false }
        guard let time, let lastTime else { return true }
        let gap = time - lastTime
        return gap >= 0 && gap <= Self.longestGap
    }

    mutating func record(epoch: Int, time: Double?) {
        self.epoch = epoch
        lastTime = time
        filled = true
    }

    mutating func forget() {
        self = DenoiseMemory()
    }
}
