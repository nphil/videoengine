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
    /// ratio, the smaller on a tie. Scales the pixel budget forbids never qualify. The display's own scaler
    /// covers the difference.
    static func factor(needed: Double, source: PixelSize, from factors: [Double], fits: (Double) -> Bool = { _ in true }) -> Double? {
        let wanted = max(min(needed, maximumScale), 1)
        let candidates = factors.filter { factor in
            factor > 1 && Double(source.pixels) * factor * factor <= Double(maximumOutputPixels) && fits(factor)
        }
        return candidates.min { lhs, rhs in
            let left = abs(log(lhs / wanted)), right = abs(log(rhs / wanted))
            return left == right ? lhs < rhs : left < right
        }
    }

    /// What a fixed-factor scaler does with a picture.
    enum FactorVerdict: Equatable {
        /// Run at this factor.
        case use(Double)
        /// Leave this scaler out, and why, in words for a probe line.
        case skip(String)
    }

    /// Picks the factor a fixed-factor scaler runs at, or says why it does not run. The factors are all the scaler
    /// offers for this picture: it cannot make any other size, so a factor whose output is over the pixel budget
    /// (`maximumOutputPixels`, the same bound every scaler's output obeys) is out, however good the picture it
    /// would make. Apple's quality super-resolution offers only 4x on the iPhone 17 Pro: 4x of 720p is 14.7 MP a
    /// frame, 4x the budget, a model run that is not credible at 24 to 30 frames a second on a phone, so that scaler
    /// is skipped with a plain reason and the ladder goes on to the next rung.
    static func fixedFactor(
        needed: Double, source: PixelSize, from offered: [Double], fits: (Double) -> Bool = { _ in true }
    ) -> FactorVerdict {
        let upscales = offered.filter { $0 > 1 }
        guard let smallest = upscales.min() else {
            return .skip("it offers no scale factor above 1x for a \(source) picture (it offers \(factorList(offered)))")
        }
        if let chosen = factor(needed: needed, source: source, from: offered, fits: fits) { return .use(chosen) }
        let affordable = upscales.contains { Double(source.pixels) * $0 * $0 <= Double(maximumOutputPixels) }
        guard affordable else {
            let which = upscales.count == 1 ? "only \(factorText(smallest))x" : "nothing under \(factorText(smallest))x"
            return .skip("\(which), too costly for live video")
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
        Float((1 + 5 * strength) / 255)
    }

    /// How far the deband pass looks, in output pixels: wider for stronger smoothing, and scaled with the picture.
    static func debandRadius(_ strength: Double, scale: Double) -> Float {
        Float((4 + 12 * strength) * max(1, scale))
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
    static func explain(_ ladder: [EnhanceUpscalerKind], statuses: [EnhanceUpscalerKind: RungStatus], ceiling: Int) -> [RungReason] {
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
                    text = "chosen"
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
        guard scaler != nil || options.sharpen > 0 || options.deband > 0 else { return .idle }
        let output = scaler?.output ?? source.size
        return .run(EnhancePlan(
            upscaler: scaler?.kind, sourceWidth: source.size.width, sourceHeight: source.size.height,
            outputWidth: output.width, outputHeight: output.height, sharpen: options.sharpen, deband: options.deband
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
