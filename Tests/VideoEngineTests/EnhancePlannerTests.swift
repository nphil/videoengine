import CoreVideo
import Foundation
import Testing
@testable import VideoEngine

struct EnhanceOptionsTests {
    @Test func startsWithEveryStageOff() {
        let options = EnhanceOptions()
        #expect(options == .off)
        #expect(!options.isEnabled)
        #expect(options.upscaler == .off)
    }

    @Test func clampsStrengthsToTheUnitRange() {
        var options = EnhanceOptions(upscaler: .automatic, sharpen: 3, deband: -1)
        #expect(options.sharpen == 1)
        #expect(options.deband == 0)
        options.sharpen = -0.5
        options.deband = .nan
        #expect(options.sharpen == 0)
        #expect(options.deband == 0)
        options.deband = 0.4
        #expect(options.deband == 0.4)
    }

    @Test func anyStageTurnsItOn() {
        #expect(EnhanceOptions(upscaler: .lineArt).isEnabled)
        #expect(EnhanceOptions(sharpen: 0.1).isEnabled)
        #expect(EnhanceOptions(deband: 0.1).isEnabled)
    }

    @Test func plainEnglishNamesExistForEveryScalerAndReason() {
        for kind in EnhanceUpscalerKind.allCases { #expect(!kind.label.isEmpty) }
        #expect(EnhanceUnavailableReason.highDynamicRange.message.contains("HDR"))
        #expect(Set(EnhanceUpscalerKind.allCases.map(\.rawValue)).count == EnhanceUpscalerKind.allCases.count)
    }
}

struct EnhanceMathTests {
    private static let phone = PixelSize(width: 2556, height: 1179)

    private func picture(_ width: Int, _ height: Int, aspect: Double = 1) -> SourcePicture {
        SourcePicture(size: PixelSize(width: width, height: height), pixelAspect: aspect)
    }

    @Test func fitScaleIsTheTighterSide() {
        let scale = EnhanceMath.fitScale(source: picture(1280, 720), target: Self.phone)
        #expect(abs(scale - 1179.0 / 720.0) < 1e-9)
        // 4:3 on a 4:3 display.
        #expect(abs(EnhanceMath.fitScale(source: picture(640, 480), target: PixelSize(width: 2752, height: 2064)) - 4.3) < 1e-9)
    }

    @Test func fitScaleCountsNonSquarePixels() {
        // DVD widescreen: 720x480 with 32:27 pixels shows as 853x480.
        let scale = EnhanceMath.fitScale(source: picture(720, 480, aspect: 32.0 / 27.0), target: Self.phone)
        #expect(abs(scale - 1179.0 / 480.0) < 1e-9)
        let narrow = EnhanceMath.fitScale(source: picture(720, 480, aspect: 32.0 / 27.0), target: PixelSize(width: 1000, height: 2000))
        #expect(abs(narrow - 1000.0 / (720.0 * 32.0 / 27.0)) < 1e-9)
    }

    @Test func fitScaleIsNeutralWhenASizeIsUnknown() {
        #expect(EnhanceMath.fitScale(source: picture(1280, 720), target: PixelSize(width: 0, height: 0)) == 1)
        #expect(EnhanceMath.fitScale(source: picture(0, 0), target: Self.phone) == 1)
    }

    @Test func freeScalersFillTheDisplayWithinTheBudget() throws {
        let output = try #require(EnhanceMath.freeOutput(source: PixelSize(width: 1280, height: 720), scale: 1179.0 / 720.0))
        #expect(output == PixelSize(width: 2096, height: 1179))
        // A 480p picture on a big display stops at the pixel budget, not at the display.
        let capped = try #require(EnhanceMath.freeOutput(source: PixelSize(width: 640, height: 480), scale: 4.3))
        #expect(Double(capped.pixels) <= Double(EnhanceMath.maximumOutputPixels) * 1.001)
        #expect(capped.width > 2100)
        // Aspect is kept.
        #expect(abs(Double(capped.width) / Double(capped.height) - 640.0 / 480.0) < 0.01)
    }

    @Test func freeScalersStopAtFourTimes() throws {
        let output = try #require(EnhanceMath.freeOutput(source: PixelSize(width: 320, height: 240), scale: 9))
        #expect(output == PixelSize(width: 1280, height: 960))
    }

    @Test func tinyGainsAreNotWorthAPass() {
        #expect(EnhanceMath.freeOutput(source: PixelSize(width: 1920, height: 1080), scale: 1.05) == nil)
        #expect(EnhanceMath.freeOutput(source: PixelSize(width: 1920, height: 1080), scale: 1.1) != nil)
    }

    @Test func fixedFactorScalersTakeTheNearestFactor() {
        let source = PixelSize(width: 640, height: 360)
        let factors = [1.5, 2, 3, 4]
        #expect(EnhanceMath.factor(needed: 1.6375, source: source, from: factors) == 1.5)
        #expect(EnhanceMath.factor(needed: 2.4, source: source, from: factors) == 2)
        #expect(EnhanceMath.factor(needed: 2.5, source: source, from: factors) == 3)
        // Beyond the largest factor, the largest.
        #expect(EnhanceMath.factor(needed: 9, source: PixelSize(width: 320, height: 240), from: factors) == 4)
    }

    @Test func fixedFactorScalersRespectTheBudgetAndTheirOwnLimits() {
        // 1080p at 2x is 8.3 MP: over budget, so nothing qualifies.
        #expect(EnhanceMath.factor(needed: 2, source: PixelSize(width: 1920, height: 1080), from: [2, 3]) == nil)
        // The scaler's own limit removes a factor.
        #expect(EnhanceMath.factor(needed: 2, source: PixelSize(width: 640, height: 360), from: [1.5, 2, 3], fits: { $0 != 2 }) == 1.5)
        // A factor of 1 or less is not an upscale.
        #expect(EnhanceMath.factor(needed: 2, source: PixelSize(width: 640, height: 360), from: [1, 0.5]) == nil)
    }

    @Test func factorOutputRoundsToNearest() {
        #expect(EnhanceMath.scaled(PixelSize(width: 853, height: 480), by: 1.5) == PixelSize(width: 1280, height: 720))
        #expect(EnhanceMath.scaled(PixelSize(width: 640, height: 360), by: 3) == PixelSize(width: 1920, height: 1080))
    }

    @Test func debandGrowsWithStrengthAndPictureScale() {
        #expect(abs(EnhanceMath.debandThreshold(0) - 1.0 / 255) < 1e-7)
        #expect(abs(EnhanceMath.debandThreshold(1) - 12.0 / 255) < 1e-7)
        #expect(EnhanceMath.debandRadius(0, scale: 1) == 4)
        #expect(EnhanceMath.debandRadius(1, scale: 2) == 32)
        // A picture that was not enlarged never shrinks the radius.
        #expect(EnhanceMath.debandRadius(0.5, scale: 0.5) == EnhanceMath.debandRadius(0.5, scale: 1))
    }
}

struct EnhanceLadderTests {
    private let automatic = EnhanceLadder.rungs(for: .automatic)

    @Test func ladderOrderIsBestFirstWithAFloor() {
        #expect(automatic == [.videoToolboxSuperResolution, .videoToolboxLowLatency, .metalFXSpatial, .lanczos])
        #expect(EnhanceLadder.rungs(for: .lineArt) == [.lineArt, .lanczos])
        #expect(EnhanceLadder.rungs(for: .off).isEmpty)
    }

    @Test func theFloorIsPreparedFirstThenTheBetterRungsBestFirst() {
        var statuses: [EnhanceUpscalerKind: RungStatus] = [:]
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: statuses, ceiling: 0) == .lanczos)
        statuses[.lanczos] = .preparing
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: statuses, ceiling: 0) == nil)
        statuses[.lanczos] = .ready(PixelSize(width: 2096, height: 1179))
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: statuses, ceiling: 0) == .videoToolboxSuperResolution)
        statuses[.videoToolboxSuperResolution] = .failed("model not downloaded")
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: statuses, ceiling: 0) == .videoToolboxLowLatency)
        statuses[.videoToolboxLowLatency] = .failed("not supported")
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: statuses, ceiling: 0) == .metalFXSpatial)
        statuses[.metalFXSpatial] = .ready(PixelSize(width: 2096, height: 1179))
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: statuses, ceiling: 0) == nil)
    }

    @Test func aRungBelowTheOneInUseIsNeverPrepared() {
        let size = PixelSize(width: 1920, height: 1080)
        let statuses: [EnhanceUpscalerKind: RungStatus] = [.lanczos: .ready(size), .videoToolboxSuperResolution: .ready(size)]
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: statuses, ceiling: 0) == nil)
        #expect(EnhanceLadder.active(automatic, statuses: statuses, ceiling: 0)?.kind == .videoToolboxSuperResolution)
    }

    @Test func theCeilingHidesRungsAboveIt() {
        let size = PixelSize(width: 1920, height: 1080)
        let statuses: [EnhanceUpscalerKind: RungStatus] = [
            .videoToolboxSuperResolution: .ready(size), .videoToolboxLowLatency: .ready(size), .lanczos: .ready(size),
        ]
        #expect(EnhanceLadder.active(automatic, statuses: statuses, ceiling: 0)?.rank == 0)
        #expect(EnhanceLadder.active(automatic, statuses: statuses, ceiling: 1)?.kind == .videoToolboxLowLatency)
        #expect(EnhanceLadder.active(automatic, statuses: statuses, ceiling: 2)?.kind == .lanczos)
        #expect(EnhanceLadder.active(automatic, statuses: statuses, ceiling: 4) == nil)
        // A demoted chain never goes back to prepare the rungs above its ceiling.
        let demoted: [EnhanceUpscalerKind: RungStatus] = [.lanczos: .ready(size), .videoToolboxLowLatency: .failed("not supported")]
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: demoted, ceiling: 0) == .videoToolboxSuperResolution)
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: demoted, ceiling: 1) == .metalFXSpatial)
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: demoted, ceiling: 3) == nil)
    }

    @Test func aRungThatIsNotReadyIsSkipped() {
        let size = PixelSize(width: 1920, height: 1080)
        let statuses: [EnhanceUpscalerKind: RungStatus] = [
            .videoToolboxSuperResolution: .preparing, .videoToolboxLowLatency: .failed("x"), .metalFXSpatial: .ready(size),
        ]
        #expect(EnhanceLadder.active(automatic, statuses: statuses, ceiling: 0)?.kind == .metalFXSpatial)
    }
}

struct EnhanceDecisionTests {
    private static let upscaled = PixelSize(width: 2096, height: 1179)

    private func context(
        _ options: EnhanceOptions, source: SourcePicture? = SourcePicture(size: PixelSize(width: 1280, height: 720)),
        target: PixelSize = PixelSize(width: 2556, height: 1179),
        ready: [EnhanceUpscalerKind: RungStatus] = [.lanczos: .ready(PixelSize(width: 2096, height: 1179))]
    ) -> EnhanceContext {
        EnhanceContext(options: options, source: source, target: target, statuses: ready)
    }

    @Test func nothingAskedForLeavesThePicture() {
        #expect(EnhanceMath.decide(context(.off)) == .idle)
        var hdr = SourcePicture(size: PixelSize(width: 3840, height: 2160))
        hdr.range = .hdr
        #expect(EnhanceMath.decide(context(.off, source: hdr)) == .idle)
    }

    @Test func waitsForTheFirstFrame() {
        #expect(EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic), source: nil)) == .idle)
        #expect(EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic), source: SourcePicture(size: PixelSize(width: 0, height: 0)))) == .idle)
    }

    @Test func hdrIsNeverEnhanced() {
        var hdr = SourcePicture(size: PixelSize(width: 3840, height: 2160))
        hdr.range = .hdr
        #expect(EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic, sharpen: 1), source: hdr)) == .unavailable(.highDynamicRange))
        // It wins over a power pause: it will not change by waiting.
        var hot = context(EnhanceOptions(sharpen: 1), source: hdr)
        hot.shedPower = true
        #expect(EnhanceMath.decide(hot) == .unavailable(.highDynamicRange))
    }

    @Test func refusedPicturesAndMissingGPUsAreUnavailable() {
        var cropped = SourcePicture(size: PixelSize(width: 1280, height: 720))
        cropped.refusal = "its frames are not 8-bit 4:2:0"
        #expect(EnhanceMath.decide(context(EnhanceOptions(sharpen: 1), source: cropped)) == .unavailable(.unsupportedPicture))
        var noGPU = context(EnhanceOptions(sharpen: 1))
        noGPU.hasGPU = false
        #expect(EnhanceMath.decide(noGPU) == .unavailable(.noGPU))
    }

    @Test func powerSavingAndDropsPauseTheChain() {
        var current = context(EnhanceOptions(upscaler: .automatic))
        current.shedPower = true
        #expect(EnhanceMath.decide(current) == .paused(.powerSaving))
        current.shedPower = false
        current.overloaded = true
        #expect(EnhanceMath.decide(current) == .paused(.droppedFrames))
        current.shedPower = true
        #expect(EnhanceMath.decide(current) == .paused(.powerSaving))
        current.shedPower = false
        current.overloaded = false
        #expect(EnhanceMath.decide(current) != .paused(.droppedFrames))
    }

    @Test func aSmallPictureOnABigDisplayIsUpscaled() {
        let decision = EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic, sharpen: 0.3, deband: 0.5)))
        #expect(decision == .run(EnhancePlan(
            upscaler: .lanczos, sourceWidth: 1280, sourceHeight: 720, outputWidth: 2096, outputHeight: 1179,
            sharpen: 0.3, deband: 0.5
        )))
    }

    @Test func aPictureAsBigAsTheDisplayIsNotUpscaled() {
        let full = SourcePicture(size: PixelSize(width: 2556, height: 1179))
        #expect(EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic), source: full)) == .idle)
        guard case .run(let plan) = EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic, sharpen: 0.5), source: full)) else {
            Issue.record("sharpening alone should still run")
            return
        }
        #expect(plan.upscaler == nil)
        #expect(plan.outputWidth == 2556 && plan.outputHeight == 1179)
    }

    @Test func aTinyGainSkipsTheUpscaler() {
        let nearly = SourcePicture(size: PixelSize(width: 1920, height: 1080))
        let decision = EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic), source: nearly, target: PixelSize(width: 2048, height: 1152)))
        #expect(decision == .idle)
    }

    @Test func noReadyScalerMeansThePlainPictureUnlessAnotherStageIsOn() {
        #expect(EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic), ready: [:])) == .idle)
        guard case .run(let plan) = EnhanceMath.decide(context(EnhanceOptions(upscaler: .automatic, deband: 1), ready: [:])) else {
            Issue.record("debanding alone should still run")
            return
        }
        #expect(plan.upscaler == nil)
        #expect(plan.outputWidth == 1280)
    }

    @Test func lineArtUsesItsOwnLadder() {
        let ready: [EnhanceUpscalerKind: RungStatus] = [.lineArt: .ready(Self.upscaled), .lanczos: .ready(Self.upscaled)]
        guard case .run(let plan) = EnhanceMath.decide(context(EnhanceOptions(upscaler: .lineArt), ready: ready)) else {
            Issue.record("line art should run")
            return
        }
        #expect(plan.upscaler == .lineArt)
        var demoted = context(EnhanceOptions(upscaler: .lineArt), ready: ready)
        demoted.ceiling = 1
        guard case .run(let fallback) = EnhanceMath.decide(demoted) else {
            Issue.record("the floor should run")
            return
        }
        #expect(fallback.upscaler == .lanczos)
    }

    @Test func changingOptionsWhilePlayingChangesThePlan() {
        var options = EnhanceOptions(upscaler: .automatic)
        var running = context(options)
        guard case .run(let first) = EnhanceMath.decide(running) else {
            Issue.record("should run")
            return
        }
        #expect(first.sharpen == 0 && first.deband == 0 && first.upscaler == .lanczos)
        options.sharpen = 0.7
        options.upscaler = .off
        running.options = options
        guard case .run(let second) = EnhanceMath.decide(running) else {
            Issue.record("sharpening alone should run")
            return
        }
        #expect(second.upscaler == nil && second.sharpen == 0.7 && second.outputWidth == 1280)
        options.sharpen = 0
        running.options = options
        #expect(EnhanceMath.decide(running) == .idle)
    }
}

struct EnhanceGovernorTests {
    /// Feeds frames until the governor reacts, returning the first action and how many frames it took.
    private func drive(_ governor: inout EnhanceGovernor, missed: Bool, rank: Int?, lowest: Int = 3, now: TimeInterval = 100, limit: Int = 200) -> (EnhanceGovernor.Action, Int) {
        for frame in 1...limit {
            let action = governor.record(missed: missed, rank: rank, lowestRank: lowest, now: now)
            if action != .none { return (action, frame) }
        }
        return (.none, limit)
    }

    @Test func aWindowIsNeededBeforeAnythingHappens() {
        var monitor = DropMonitor()
        for _ in 0..<(DropMonitor.window - 1) { monitor.record(missed: true) }
        #expect(!monitor.isOverloaded)
        monitor.record(missed: true)
        #expect(monitor.isOverloaded)
    }

    @Test func aFewMissesDoNotCount() {
        var monitor = DropMonitor()
        for frame in 0..<300 { monitor.record(missed: frame % 5 == 0) }
        #expect(monitor.missed == 6)
        #expect(!monitor.isOverloaded)
    }

    @Test func missesAgeOutOfTheWindow() {
        var monitor = DropMonitor()
        for _ in 0..<DropMonitor.window { monitor.record(missed: true) }
        #expect(monitor.isOverloaded)
        for _ in 0..<DropMonitor.window { monitor.record(missed: false) }
        #expect(monitor.missed == 0)
        #expect(!monitor.isOverloaded)
    }

    @Test func warmUpFramesAreNotCounted() {
        var governor = EnhanceGovernor()
        let (action, frames) = drive(&governor, missed: true, rank: 0)
        #expect(action == .demote)
        #expect(frames == EnhanceGovernor.warmUpFrames + DropMonitor.window)
    }

    @Test func overloadStepsDownTheLadderBeforeItPauses() {
        var governor = EnhanceGovernor()
        for expectedCeiling in 1...3 {
            let (action, _) = drive(&governor, missed: true, rank: expectedCeiling - 1)
            #expect(action == .demote)
            #expect(governor.ceiling == expectedCeiling)
        }
        let (action, _) = drive(&governor, missed: true, rank: 3, now: 50)
        #expect(action == .pause(until: 60))
        #expect(governor.isPaused)
    }

    @Test func aPausedChainIgnoresFramesAndResumesAfterTheCooldown() {
        var governor = EnhanceGovernor()
        let (action, _) = drive(&governor, missed: true, rank: nil, now: 50)
        #expect(action == .pause(until: 60))
        let whilePaused = governor.record(missed: true, rank: nil, lowestRank: 3, now: 51)
        #expect(whilePaused == .none)
        let early = governor.resume(now: 59.9)
        #expect(!early)
        let onTime = governor.resume(now: 60)
        #expect(onTime)
        let again = governor.resume(now: 61)
        #expect(!again)
        #expect(!governor.isPaused)
    }

    @Test func cooldownsDoubleAndTheThirdPauseIsFinal() {
        var governor = EnhanceGovernor()
        var now = 0.0
        for cooldown in EnhanceGovernor.cooldowns {
            let (action, _) = drive(&governor, missed: true, rank: nil, now: now)
            #expect(action == .pause(until: now + cooldown))
            now += cooldown
            let resumed = governor.resume(now: now)
            #expect(resumed)
        }
        let (final, _) = drive(&governor, missed: true, rank: nil, now: now)
        #expect(final == .retire)
        #expect(governor.retired)
        let afterRetire = governor.resume(now: now + 1_000)
        #expect(!afterRetire)
        governor.reset()
        #expect(!governor.isPaused)
        #expect(governor.ceiling == 0)
    }

    @Test func aHealthyChainIsLeftAlone() {
        var governor = EnhanceGovernor()
        let (action, _) = drive(&governor, missed: false, rank: 0, limit: 500)
        #expect(action == .none)
        #expect(governor.ceiling == 0)
    }

    @Test func restartingTheCountGivesTheNewRungAWarmUp() {
        var governor = EnhanceGovernor()
        _ = drive(&governor, missed: true, rank: 0)
        governor.restartCount()
        for _ in 0..<EnhanceGovernor.warmUpFrames {
            let action = governor.record(missed: true, rank: 1, lowestRank: 3, now: 0)
            #expect(action == .none)
        }
        // After the warm-up a full window of misses is needed before the next step down.
        let (action, frames) = drive(&governor, missed: true, rank: 1)
        #expect(action == .demote)
        #expect(frames == DropMonitor.window)
    }
}

struct EnhanceColorTests {
    private func rgb(_ matrix: YCbCrMatrix, fullRange: Bool = false, y: Float, cb: Float, cr: Float) -> (r: Float, g: Float, b: Float) {
        IngestCoefficients(matrix: matrix, fullRange: fullRange).rgb(y: y / 255, cb: cb / 255, cr: cr / 255)
    }

    @Test func videoRangeBlackAndWhiteMapToTheEnds() {
        for matrix in [YCbCrMatrix.bt601, .bt709, .bt2020] {
            let black = rgb(matrix, y: 16, cb: 128, cr: 128)
            #expect(abs(black.r) < 1e-5 && abs(black.g) < 1e-5 && abs(black.b) < 1e-5)
            let white = rgb(matrix, y: 235, cb: 128, cr: 128)
            #expect(abs(white.r - 1) < 1e-5 && abs(white.g - 1) < 1e-5 && abs(white.b - 1) < 1e-5)
        }
    }

    @Test func fullRangeUsesEveryStep() {
        let white = rgb(.bt709, fullRange: true, y: 255, cb: 128, cr: 128)
        #expect(abs(white.r - 1) < 1e-5 && abs(white.b - 1) < 1e-5)
        let black = rgb(.bt709, fullRange: true, y: 0, cb: 128, cr: 128)
        #expect(abs(black.g) < 1e-5)
    }

    @Test func primariesComeOutRightForTheirMatrix() {
        // Studio-swing 8-bit values of pure red under each matrix.
        let red709 = rgb(.bt709, y: 63, cb: 102, cr: 240)
        #expect(abs(red709.r - 1) < 0.01 && abs(red709.g) < 0.02 && abs(red709.b) < 0.02)
        let red601 = rgb(.bt601, y: 81, cb: 90, cr: 240)
        #expect(abs(red601.r - 1) < 0.01 && abs(red601.g) < 0.02 && abs(red601.b) < 0.02)
        // The same samples read with the wrong matrix come out visibly wrong, which is why the matrix is read per frame.
        let wrong = rgb(.bt601, y: 63, cb: 102, cr: 240)
        #expect(abs(wrong.g - red709.g) > 0.05 || abs(wrong.r - red709.r) > 0.05)
    }

    @Test func blueAndGreenPrimaries() {
        let blue = rgb(.bt709, y: 32, cb: 240, cr: 118)
        #expect(abs(blue.b - 1) < 0.01 && abs(blue.r) < 0.02 && abs(blue.g) < 0.02)
        let green = rgb(.bt709, y: 173, cb: 42, cr: 26)
        #expect(abs(green.g - 1) < 0.01 && abs(green.r) < 0.02 && abs(green.b) < 0.02)
    }

    @Test func untaggedPicturesAreAssumedByTheirSize() {
        #expect(YCbCrMatrix.assumed(for: PixelSize(width: 1920, height: 800)) == .bt709)
        #expect(YCbCrMatrix.assumed(for: PixelSize(width: 1280, height: 536)) == .bt709)
        #expect(YCbCrMatrix.assumed(for: PixelSize(width: 720, height: 480)) == .bt601)
        #expect(YCbCrMatrix.assumed(for: PixelSize(width: 640, height: 360)) == .bt601)
    }
}

struct LanczosTapsTests {
    @Test func everyRowSumsToOne() {
        for (source, output) in [(640, 1280), (1280, 2096), (720, 1179), (480, 1663), (100, 110)] {
            let taps = LanczosTaps(source: source, output: output)
            #expect(taps.starts.count == output)
            #expect(taps.weights.count == output * LanczosTaps.count)
            for row in 0..<output {
                let sum = taps.weights[(row * LanczosTaps.count)..<((row + 1) * LanczosTaps.count)].reduce(0, +)
                #expect(abs(sum - 1) < 1e-5)
            }
        }
    }

    @Test func sameSizeIsTheIdentity() {
        let taps = LanczosTaps(source: 16, output: 16)
        for row in 0..<16 {
            #expect(Int(taps.starts[row]) == row - 2)
            let weights = Array(taps.weights[(row * 6)..<((row + 1) * 6)])
            #expect(abs(weights[2] - 1) < 1e-6)
            #expect(weights.enumerated().allSatisfy { $0.offset == 2 || abs($0.element) < 1e-6 })
        }
    }

    @Test func aFlatLineStaysFlat() {
        let taps = LanczosTaps(source: 8, output: 20)
        let line = [Float](repeating: 0.6, count: 8)
        for row in 0..<20 {
            var value: Float = 0
            for tap in 0..<LanczosTaps.count {
                let index = min(max(Int(taps.starts[row]) + tap, 0), 7)
                value += taps.weights[row * LanczosTaps.count + tap] * line[index]
            }
            #expect(abs(value - 0.6) < 1e-5)
        }
    }

    @Test func theFirstRowReadsPastTheLeftEdge() {
        let taps = LanczosTaps(source: 4, output: 8)
        #expect(taps.starts[0] == -3)
        // Mirror image: the last row reads past the right edge by the same amount.
        let last = Int(taps.starts[7]) + LanczosTaps.count - 1
        #expect(last == 4 + 2)
    }

    @Test func aStepKeepsItsSideOfTheEdge() {
        // A step from 0 to 1 at the middle of 8 samples, stretched 2x: left of the edge stays low and right stays high.
        let taps = LanczosTaps(source: 8, output: 16)
        let line: [Float] = [0, 0, 0, 0, 1, 1, 1, 1]
        func sample(_ row: Int) -> Float {
            (0..<LanczosTaps.count).reduce(0) { sum, tap in
                sum + taps.weights[row * LanczosTaps.count + tap] * line[min(max(Int(taps.starts[row]) + tap, 0), 7)]
            }
        }
        #expect(sample(2) < 0.05)
        #expect(sample(13) > 0.95)
        #expect(sample(7) < sample(8))
    }
}

struct EnhanceFormatTests {
    private let bgra = ScalerFormat.bgra.code
    private let video = ScalerFormat.nv12VideoRange.code
    private let full = OSType(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

    @Test func theChainsOwnFormatComesFirstThenTheOneAppleTakes() {
        #expect(EnhanceFormats.choose([video, bgra]) == .bgra)
        #expect(EnhanceFormats.choose([video]) == .nv12VideoRange)
        #expect(EnhanceFormats.choose([full, video]) == .nv12VideoRange)
    }

    @Test func aFormatTheChainCannotConvertIsNotChosen() {
        #expect(EnhanceFormats.choose([full]) == nil)
        #expect(EnhanceFormats.choose([]) == nil)
    }

    @Test func theLowLatencyScalerThatTakes420vAndNotBGRAGets420v() {
        // What the iPhone 17 Pro's low-latency scaler reported: "it does not take BGRA pictures (it takes 420v)".
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: video)]
        let offered = EnhanceFormats.offered(attributes: attributes, supported: [video])
        #expect(offered == [video])
        #expect(EnhanceFormats.choose(offered) == .nv12VideoRange)
    }

    @Test func aListOfFormatsInTheAttributesIsReadAndHeldToWhatIsSupported() {
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: [NSNumber(value: bgra), NSNumber(value: video)]]
        #expect(EnhanceFormats.offered(attributes: attributes, supported: [video, full]) == [video])
        #expect(EnhanceFormats.offered(attributes: attributes, supported: [bgra, video]) == [bgra, video])
    }

    @Test func whicheverSideNamesFormatsIsUsedWhenTheOtherIsSilent() {
        let silent: [String: Any] = [:]
        #expect(EnhanceFormats.offered(attributes: silent, supported: [bgra]) == [bgra])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: video)]
        #expect(EnhanceFormats.offered(attributes: attributes, supported: []) == [video])
        // Two lists that share nothing: the scaler's own supported list wins.
        #expect(EnhanceFormats.offered(attributes: attributes, supported: [full]) == [full])
    }
}

struct EnhanceFixedFactorTests {
    private let hd = PixelSize(width: 1280, height: 720)

    @Test func aScalerThatOffersOnly4xIsSkippedForLiveVideo() {
        // Measured on iPhone 17 Pro: the quality scaler offers [4] and 4x of 720p is 5120x2880.
        let verdict = EnhanceMath.fixedFactor(needed: 1.67, source: hd, from: [4])
        #expect(verdict == .skip("only 4x, too costly for live video"))
    }

    @Test func severalFactorsAllTooBigAreSkippedWithTheSmallestNamed() {
        let verdict = EnhanceMath.fixedFactor(needed: 1.5, source: hd, from: [3, 4])
        #expect(verdict == .skip("nothing under 3x, too costly for live video"))
    }

    @Test func aSmallPictureCanTake4x() {
        let small = PixelSize(width: 640, height: 360)
        #expect(EnhanceMath.fixedFactor(needed: 4, source: small, from: [4]) == .use(4))
    }

    @Test func theNearestAffordableFactorIsUsed() {
        #expect(EnhanceMath.fixedFactor(needed: 1.9, source: hd, from: [1.5, 2, 4]) == .use(2))
    }

    @Test func aFactorTheScalerRefusesIsNotTooCostlyJustUnavailable() {
        let verdict = EnhanceMath.fixedFactor(needed: 1.7, source: hd, from: [2], fits: { _ in false })
        #expect(verdict == .skip("no scale factor fits a 1280x720 picture (it offers [2x])"))
    }

    @Test func nothingAbove1xIsASkipToo() {
        guard case .skip(let reason) = EnhanceMath.fixedFactor(needed: 1.7, source: hd, from: []) else {
            Issue.record("expected a skip")
            return
        }
        #expect(reason.contains("no scale factor above 1x"))
    }
}

struct EnhanceRungDecisionTests {
    private let automatic = EnhanceLadder.rungs(for: .automatic)
    private let size = PixelSize(width: 2144, height: 1206)
    private let skipText = "only 4x, too costly for live video"

    private func statuses(lowLatency: RungStatus) -> [EnhanceUpscalerKind: RungStatus] {
        [
            .lanczos: .ready(size), .metalFXSpatial: .ready(size),
            .videoToolboxSuperResolution: .skipped(skipText), .videoToolboxLowLatency: lowLatency,
        ]
    }

    @Test func with4xOnlyQualityScalerTheLowLatencyScalerIsChosen() {
        let all = statuses(lowLatency: .ready(size))
        #expect(EnhanceLadder.active(automatic, statuses: all, ceiling: 0)?.kind == .videoToolboxLowLatency)
    }

    @Test func whenLowLatencyFailsToo() {
        let all = statuses(lowLatency: .failed("it does not take BGRA pictures (it takes 420v)"))
        #expect(EnhanceLadder.active(automatic, statuses: all, ceiling: 0)?.kind == .metalFXSpatial)
    }

    @Test func aSkippedRungIsNotPreparedAgain() {
        let all = statuses(lowLatency: .ready(size))
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: all, ceiling: 0) == nil)
        var waiting = all
        waiting[.videoToolboxLowLatency] = nil
        #expect(EnhanceLadder.nextToPrepare(automatic, statuses: waiting, ceiling: 0) == .videoToolboxLowLatency)
    }

    @Test func theExplanationNamesWhyEachRungIsOrIsNotInUse() {
        let all = statuses(lowLatency: .ready(size))
        let reasons = EnhanceLadder.explain(automatic, statuses: all, ceiling: 0)
        #expect(reasons.map(\.kind) == automatic)
        #expect(reasons.map(\.text) == [
            "skipped: \(skipText)", "chosen", "not needed: a better rung is in use", "not needed: a better rung is in use",
        ])
    }

    @Test func aDemotedRungIsExplainedAsSuch() {
        let all = statuses(lowLatency: .ready(size))
        let reasons = EnhanceLadder.explain(automatic, statuses: all, ceiling: 2)
        #expect(reasons.map(\.text) == [
            "skipped: \(skipText)", "demoted: it dropped frames", "chosen", "not needed: a better rung is in use",
        ])
    }

    @Test func aFailureIsExplainedWithItsReason() {
        let all = statuses(lowLatency: .failed("not supported"))
        let reasons = EnhanceLadder.explain(automatic, statuses: all, ceiling: 0)
        #expect(reasons[1].text == "failed: not supported")
        #expect(reasons[2].text == "chosen")
    }

    @Test func theExplanationWaitsUntilEveryRungHasAnAnswer() {
        var all = statuses(lowLatency: .ready(size))
        #expect(EnhanceLadder.isSettled(automatic, statuses: all, ceiling: 0))
        all[.videoToolboxLowLatency] = .preparing
        #expect(!EnhanceLadder.isSettled(automatic, statuses: all, ceiling: 0))
        all[.videoToolboxLowLatency] = nil
        #expect(!EnhanceLadder.isSettled(automatic, statuses: all, ceiling: 0))
    }
}

struct EnhanceOptionsFlowTests {
    private let base = EnhanceOptions(upscaler: .automatic, sharpen: 0.3, deband: 0.2)

    private func with(sharpen: Double) -> EnhanceOptions {
        var changed = base
        changed.sharpen = sharpen
        return changed
    }

    @Test func aStrengthChangeIsTuningAndNeverRebuildsTheScaler() {
        #expect(with(sharpen: 0.35).change(from: base) == .tuning)
        var deband = base
        deband.deband = 0.5
        #expect(deband.change(from: base) == .tuning)
        #expect(base.change(from: base) == .none)
    }

    @Test func aDifferentScalerOrTurningTheChainOnOrOffIsStructural() {
        var other = base
        other.upscaler = .lineArt
        #expect(other.change(from: base) == .structural)
        #expect(EnhanceOptions.off.change(from: base) == .structural)
        #expect(base.change(from: .off) == .structural)
        // Strengths with the scaler off still turn the chain on.
        #expect(EnhanceOptions(sharpen: 0.3).change(from: .off) == .structural)
    }

    @Test func theFirstStrengthChangeAppliesAtOnce() {
        var coalescer = OptionsCoalescer()
        #expect(coalescer.request(with(sharpen: 0.35), current: base, now: 10) == with(sharpen: 0.35))
        #expect(coalescer.pending == nil)
    }

    @Test func aDragKeepsOnlyTheNewestStepAndAppliesItWhenTheIntervalIsOver() {
        var coalescer = OptionsCoalescer()
        var current = base
        let first = coalescer.request(with(sharpen: 0.35), current: current, now: 10)
        current = first ?? current
        #expect(coalescer.request(with(sharpen: 0.40), current: current, now: 10.02) == nil)
        #expect(coalescer.request(with(sharpen: 0.45), current: current, now: 10.05) == nil)
        #expect(coalescer.pending == with(sharpen: 0.45))
        let wait = coalescer.delay(now: 10.05) ?? -1
        #expect(abs(wait - 0.05) < 1e-9)
        #expect(coalescer.due(current: current, now: 10.07) == nil)
        #expect(coalescer.due(current: current, now: 10.11) == with(sharpen: 0.45))
        #expect(coalescer.pending == nil)
        #expect(coalescer.delay(now: 10.11) == nil)
    }

    @Test func aScalerChangeDuringADragAppliesAtOnceWithoutWaiting() {
        var coalescer = OptionsCoalescer()
        _ = coalescer.request(with(sharpen: 0.35), current: base, now: 10)
        var other = with(sharpen: 0.4)
        other.upscaler = .lineArt
        #expect(coalescer.request(other, current: with(sharpen: 0.35), now: 10.01) == other)
    }

    @Test func draggingBackToWhatIsAppliedDropsTheHeldChange() {
        var coalescer = OptionsCoalescer()
        let applied = coalescer.request(with(sharpen: 0.35), current: base, now: 10) ?? base
        #expect(coalescer.request(with(sharpen: 0.4), current: applied, now: 10.01) == nil)
        #expect(coalescer.pending != nil)
        #expect(coalescer.request(applied, current: applied, now: 10.02) == nil)
        #expect(coalescer.pending == nil)
        #expect(coalescer.due(current: applied, now: 11) == nil)
    }

    @Test func aHeldChangeAMomentLaterThanTheIntervalAppliesOnTheNextRequest() {
        var coalescer = OptionsCoalescer()
        let applied = coalescer.request(with(sharpen: 0.35), current: base, now: 10) ?? base
        #expect(coalescer.request(with(sharpen: 0.5), current: applied, now: 10.5) == with(sharpen: 0.5))
    }

    @Test func tenStepsInAHalfSecondDragApplyAboutFiveTimes() {
        var coalescer = OptionsCoalescer()
        var current = base
        var applied = 0
        for step in 0..<10 {
            let now = 20 + Double(step) * 0.05
            if let next = coalescer.request(with(sharpen: 0.3 + 0.05 * Double(step + 1)), current: current, now: now) {
                current = next
                applied += 1
            } else if let due = coalescer.due(current: current, now: now) {
                current = due
                applied += 1
            }
        }
        #expect(applied >= 4 && applied <= 6)
    }
}

// MARK: v3.1.0: denoise, deblock, vivid and the low-resolution ladder

struct EnhanceEffectOptionsTests {
    @Test func theNewStagesStartOffAndAreClamped() {
        let options = EnhanceOptions()
        #expect(options.denoise == 0 && options.deblock == 0 && options.vivid == 0)
        var changed = EnhanceOptions(upscaler: .automatic, denoise: 4, deblock: -1, vivid: 0.5)
        #expect(changed.denoise == 1 && changed.deblock == 0 && changed.vivid == 0.5)
        changed.denoise = .nan
        changed.vivid = -3
        changed.deblock = 7
        #expect(changed.denoise == 0 && changed.vivid == 0 && changed.deblock == 1)
    }

    @Test func eachNewStageAloneTurnsTheChainOn() {
        #expect(EnhanceOptions(denoise: 0.1).isEnabled)
        #expect(EnhanceOptions(deblock: 0.1).isEnabled)
        #expect(EnhanceOptions(vivid: 0.1).isEnabled)
        #expect(!EnhanceOptions(denoise: 0, deblock: 0, vivid: 0).isEnabled)
    }

    @Test func theLabelledInitKeepsTheOldCallsWorking() {
        let old = EnhanceOptions(upscaler: .lineArt, sharpen: 0.2, deband: 0.3)
        #expect(old.denoise == 0 && old.deblock == 0 && old.vivid == 0)
    }

    @Test func strengthChangesOfTheNewStagesAreTuningAndCoalesce() {
        let base = EnhanceOptions(upscaler: .automatic, sharpen: 0.3, denoise: 0.2, deblock: 0.2, vivid: 0.2)
        for edit in [
            { (o: inout EnhanceOptions) in o.denoise = 0.6 }, { (o: inout EnhanceOptions) in o.deblock = 0.6 },
            { (o: inout EnhanceOptions) in o.vivid = 0.6 },
        ] {
            var changed = base
            edit(&changed)
            #expect(changed.change(from: base) == .tuning)
        }
        var coalescer = OptionsCoalescer()
        var first = base
        first.vivid = 0.3
        #expect(coalescer.request(first, current: base, now: 10) == first)
        var second = first
        second.vivid = 0.4
        #expect(coalescer.request(second, current: first, now: 10.02) == nil)
        var third = second
        third.denoise = 0.9
        #expect(coalescer.request(third, current: first, now: 10.04) == nil)
        #expect(coalescer.pending == third)
        #expect(coalescer.due(current: first, now: 10.2) == third)
    }

    @Test func thePlanCarriesTheNewStrengthsAndCountsItsExtraPasses() {
        var plan = EnhancePlan(upscaler: nil, sourceWidth: 640, sourceHeight: 360, outputWidth: 640, outputHeight: 360, sharpen: 0, deband: 0)
        #expect(plan.denoise == 0 && plan.deblock == 0 && plan.vivid == 0)
        #expect(plan.extraPasses == 0)
        plan.deblock = 1
        plan.vivid = 1
        #expect(plan.extraPasses == 0)
        plan.denoise = 0.5
        #expect(plan.extraPasses == 1)
    }

    @Test func theNewStagesAloneRunAtTheSourceSize() {
        let source = SourcePicture(size: PixelSize(width: 1280, height: 720))
        let context = EnhanceContext(
            options: EnhanceOptions(denoise: 0.5, deblock: 0.25, vivid: 0.75), source: source,
            target: PixelSize(width: 2556, height: 1179), statuses: [:]
        )
        guard case .run(let plan) = EnhanceMath.decide(context) else {
            Issue.record("the new stages alone should run")
            return
        }
        #expect(plan.upscaler == nil && plan.outputWidth == 1280 && plan.outputHeight == 720)
        #expect(plan.denoise == 0.5 && plan.deblock == 0.25 && plan.vivid == 0.75)
        #expect(plan.sharpen == 0 && plan.deband == 0)
    }

    @Test func theStrengthMappingsGrowWithStrengthAndStayInRange() {
        let steps = stride(from: 0.0, through: 1.0, by: 0.25).map { $0 }
        func rises(_ map: (Double) -> Float) -> Bool {
            let values = steps.map(map)
            return zip(values, values.dropFirst()).allSatisfy { $0 < $1 } && values.allSatisfy { $0 > 0 && $0 < 1 }
        }
        #expect(rises(EnhanceMath.denoiseRange))
        #expect(rises(EnhanceMath.denoiseSpatialAmount))
        #expect(rises(EnhanceMath.denoiseTolerance))
        #expect(rises(EnhanceMath.denoiseHistoryWeight))
        #expect(rises(EnhanceMath.deblockStep))
        #expect(rises(EnhanceMath.deblockActivity))
        #expect(EnhanceMath.deblockAmount(1) == 1)
        #expect(EnhanceMath.deblockAmount(0.1) < EnhanceMath.deblockAmount(0.3))
        #expect(EnhanceMath.denoiseHistoryWeight(1) <= 0.9 + 1e-6)
    }

    @Test func theDitherFollowsTheStagesThatNeedIt() {
        #expect(EnhanceMath.ditherCodes(deband: 0, denoise: 0, vivid: 0) == 0)
        #expect(EnhanceMath.ditherCodes(deband: 1, denoise: 0, vivid: 0) == 1)
        #expect(EnhanceMath.ditherCodes(deband: 0.2, denoise: 0, vivid: 0) == 0.6)
        #expect(EnhanceMath.ditherCodes(deband: 0, denoise: 0.1, vivid: 0) == 0.75)
        #expect(EnhanceMath.ditherCodes(deband: 0, denoise: 0, vivid: 0.1) == 0.5)
    }

    @Test func theDenoiserOnlyRemembersTheFrameJustBefore() {
        var memory = DenoiseMemory()
        #expect(!memory.remembers(epoch: 0, time: 0))
        memory.record(epoch: 0, time: 1.0)
        #expect(memory.remembers(epoch: 0, time: 1.04))
        #expect(memory.remembers(epoch: 0, time: nil))
        #expect(!memory.remembers(epoch: 1, time: 1.04), "a seek or a new item starts again")
        #expect(!memory.remembers(epoch: 0, time: 0.5), "time ran backwards")
        #expect(!memory.remembers(epoch: 0, time: 1.0 + DenoiseMemory.longestGap + 0.1), "too long a gap")
        memory.forget()
        #expect(!memory.remembers(epoch: 0, time: 1.04))
    }
}

struct EnhanceLowResolutionTests {
    private let phone = PixelSize(width: 2556, height: 1179)
    private let sd = PixelSize(width: 854, height: 480)

    @Test func aSmallPictureIs720pClassOrSmallerInEitherOrientation() {
        #expect(EnhanceMath.isSmallPicture(sd))
        #expect(EnhanceMath.isSmallPicture(PixelSize(width: 1280, height: 720)))
        #expect(EnhanceMath.isSmallPicture(PixelSize(width: 720, height: 1280)))
        #expect(!EnhanceMath.isSmallPicture(PixelSize(width: 1920, height: 1080)))
        #expect(!EnhanceMath.isSmallPicture(PixelSize(width: 1280, height: 960)))
    }

    @Test func the4xScalerRunsOn480pClassAndNotOn720p() {
        #expect(EnhanceMath.fixedFactor(needed: 2.456, source: sd, from: [4]) == .use(4))
        #expect(EnhanceMath.fixedFactor(needed: 2.456, source: PixelSize(width: 640, height: 480), from: [4]) == .use(4))
        #expect(EnhanceMath.fixedFactor(needed: 1.67, source: PixelSize(width: 1280, height: 720), from: [4])
            == .skip("only 4x, too costly for live video"))
    }

    @Test func aFactorMoreThanTwiceWhatTheDisplayNeedsIsSkippedWithThatReason() {
        guard case .skip(let reason) = EnhanceMath.fixedFactor(needed: 1.5, source: PixelSize(width: 640, height: 480), from: [4]) else {
            Issue.record("expected a skip")
            return
        }
        #expect(reason.contains("more than twice"))
    }

    @Test func aResultOverTheBudgetIsScaledDownToWhatTheDisplayNeeds() {
        let model = EnhanceMath.scaled(sd, by: 4)
        #expect(model.pixels > EnhanceMath.maximumOutputPixels)
        let output = EnhanceMath.rungOutput(model: model, source: sd, needed: 2.456)
        #expect(output == EnhanceMath.scaled(sd, by: 2.456))
        #expect(output.pixels <= EnhanceMath.maximumOutputPixels)
        #expect(Double(model.width) / Double(output.width) <= EnhanceMath.maximumDownscale)
        let inside = EnhanceMath.scaled(sd, by: 2)
        #expect(EnhanceMath.rungOutput(model: inside, source: sd, needed: 2.456) == inside)
    }

    @Test func aPictureThatNeedsLessThanTheBudgetNeverGetsMoreThanTheBudget() {
        let model = EnhanceMath.scaled(sd, by: 4)
        let output = EnhanceMath.rungOutput(model: model, source: sd, needed: 3.5)
        #expect(output.pixels <= EnhanceMath.maximumOutputPixels)
    }

    @Test func theBestScalerGoesFirstAndTheReasonSaysSo() {
        let automatic = EnhanceLadder.rungs(for: .automatic)
        let size = EnhanceMath.scaled(sd, by: 2.456)
        let all: [EnhanceUpscalerKind: RungStatus] = [
            .videoToolboxSuperResolution: .ready(size), .videoToolboxLowLatency: .ready(size), .metalFXSpatial: .ready(size),
            .lanczos: .ready(size),
        ]
        #expect(EnhanceLadder.active(automatic, statuses: all, ceiling: 0)?.kind == .videoToolboxSuperResolution)
        let reasons = EnhanceLadder.explain(automatic, statuses: all, ceiling: 0, smallPicture: true)
        #expect(reasons[0].text == "chosen: the best scaler, which a small picture gets first")
        #expect(reasons[1].text == "not needed: a better rung is in use")
        #expect(EnhanceLadder.explain(automatic, statuses: all, ceiling: 0)[0].text == "chosen")
    }

    @Test func theFallbackOrderIsLowLatencyThenMetalFXThenLanczos() {
        let automatic = EnhanceLadder.rungs(for: .automatic)
        let size = EnhanceMath.scaled(sd, by: 2.456)
        var all: [EnhanceUpscalerKind: RungStatus] = [
            .videoToolboxSuperResolution: .failed("no memory"), .videoToolboxLowLatency: .ready(size), .metalFXSpatial: .ready(size),
            .lanczos: .ready(size),
        ]
        #expect(EnhanceLadder.active(automatic, statuses: all, ceiling: 0)?.kind == .videoToolboxLowLatency)
        all[.videoToolboxLowLatency] = .failed("x")
        #expect(EnhanceLadder.active(automatic, statuses: all, ceiling: 0)?.kind == .metalFXSpatial)
        all[.metalFXSpatial] = .failed("x")
        #expect(EnhanceLadder.active(automatic, statuses: all, ceiling: 0)?.kind == .lanczos)
        // A late-frame demote still steps one rung down from the best.
        all = [.videoToolboxSuperResolution: .ready(size), .videoToolboxLowLatency: .ready(size), .lanczos: .ready(size)]
        #expect(EnhanceLadder.active(automatic, statuses: all, ceiling: 1)?.kind == .videoToolboxLowLatency)
    }

    @Test func thePolicyLineSaysWhichClassThePictureIsIn() {
        #expect(EnhanceMath.ladderPolicy(source: sd).contains("720p class or smaller"))
        #expect(EnhanceMath.ladderPolicy(source: PixelSize(width: 1920, height: 1080)).contains("above 720p class"))
    }
}

struct DownscaleTapsTests {
    @Test func everyRowSumsToOneAndCoversTheSamplesUnderItsOutputPixel() {
        let taps = DownscaleTaps(source: 3416, output: 2097)
        #expect(taps.starts.count == 2097 && taps.weights.count == 2097 * DownscaleTaps.count)
        for index in 0..<2097 {
            let row = taps.weights[(index * 8)..<(index * 8 + 8)]
            #expect(abs(row.reduce(0, +) - 1) < 1e-5)
        }
        // The pixel under the middle of output pixel 100 is source 100 * ratio + ratio / 2, and its tap sits in the window.
        let ratio = 3416.0 / 2097.0
        let centre = Int((100.5 * ratio - 0.5).rounded(.down))
        #expect(Int(taps.starts[100]) <= centre && centre < Int(taps.starts[100]) + 8)
    }

    @Test func aFlatLineStaysFlatAndAnEqualSizeIsTheIdentity() {
        let same = DownscaleTaps(source: 64, output: 64)
        for index in 0..<64 {
            let row = Array(same.weights[(index * 8)..<(index * 8 + 8)])
            let centre = Int(same.starts[index]) + (row.firstIndex(of: row.max() ?? 0) ?? 0)
            #expect(centre == index)
            #expect((row.max() ?? 0) > 0.99)
        }
    }
}
