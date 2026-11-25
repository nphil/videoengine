import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Testing
@testable import VideoEngine

private func hasMetal() -> Bool { MTLCreateSystemDefaultDevice() != nil }

private let needsMetal: Comment = "needs a Metal device; a simulator without one skips these, and the device sheet (ENGINE.md, E1-E8) covers the pipeline then"

private let needsSharing: Comment = "needs a GPU that reads pixel buffers without a copy; a virtual one may refuse, and the device sheet (ENGINE.md, E1-E8) covers the pipeline then"

/// The chain gives Metal the player's pixel buffers and its own pooled ones without a copy. A virtual GPU may refuse
/// that, and then the chain tests have nothing to say about the engine, so they skip.
private func canShareBuffers() -> Bool {
    guard let gpu = try? EnhanceGPU(), let video = makeBuffer(width: 64, height: 64) else { return false }
    let luma = EnhanceTextures.wrap(video, plane: 0, format: .r8Unorm, cache: gpu.cache, usage: .shaderRead)
    let chroma = EnhanceTextures.wrap(video, plane: 1, format: .rg8Unorm, cache: gpu.cache, usage: .shaderRead)
    let pool = PooledSurfaces(
        size: PixelSize(width: 64, height: 64), usage: [.shaderRead, .shaderWrite], minimum: 1, ceiling: 2, cache: gpu.cache
    )
    return luma != nil && chroma != nil && pool?.next() != nil
}

private let buffersShare = hasMetal() && canShareBuffers()

/// A flat grey frame of `format`, as the player would hand it over: Metal can read it.
private func makeBuffer(width: Int, height: Int, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) -> CVPixelBuffer? {
    let attributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var made: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &made)
    guard status == kCVReturnSuccess, let buffer = made else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    let planes = CVPixelBufferGetPlaneCount(buffer)
    if planes == 0 {
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 126, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
    } else {
        for plane in 0..<planes {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let length = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, plane == 0 ? 126 : 128, length)
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

private func tag(_ buffer: CVPixelBuffer, _ key: CFString, _ value: CFTypeRef) {
    CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
}

/// Keeps what the enhancer logs, so a failing run says what the chain was doing.
private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var logger: EngineLogger {
        EngineLogger(
            event: { [self] tag, fields in
                let text = ([tag] + fields.map { "\($0.0)=\($0.1)" }).joined(separator: " ")
                lock.lock()
                lines.append(text)
                lock.unlock()
            },
            message: { _ in }
        )
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// Feeds the enhancer one frame every 33 ms, the way the display link would, until `done` says it has seen enough.
@MainActor
private func pump(_ enhancer: PictureEnhancer, frame: CVPixelBuffer, until done: () -> Bool) async throws {
    let started = ContinuousClock.now
    var index: Int64 = 0
    while !done(), ContinuousClock.now - started < .seconds(30) {
        let now = CACurrentMediaTime()
        let pulled = PulledFrame(readOnly: nil, buffer: frame, time: CMTime(value: index, timescale: 30))
        enhancer.handle(pulled, tickTime: now, deadline: now + 10)
        index += 1
        try await Task.sleep(for: .milliseconds(33))
    }
}

private func dummyItem() -> AVPlayerItem {
    AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent.mp4"))
}

/// The enhancer around the GPU: what it reads off a frame, and that frames really come out of the chain. Speed,
/// memory and Apple's own scalers need a phone.
@MainActor
struct PictureEnhancerTests {
    @Test
    func frameFactsReadTheTagsOnTheBuffer() throws {
        let buffer = try #require(makeBuffer(width: 1920, height: 1080))
        tag(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let facts = FrameFacts(buffer: buffer, presentationSize: CGSize(width: 1920, height: 1080))
        #expect(facts.matrix == .bt601)
        #expect(!facts.fullRange)
        #expect(facts.picture.size == PixelSize(width: 1920, height: 1080))
        #expect(facts.picture.range == .sdr)
        #expect(facts.picture.refusal == nil)
    }

    @Test
    func anUntaggedFrameGetsTheMatrixItsSizeImplies() throws {
        let hd = try #require(makeBuffer(width: 1280, height: 720))
        let sd = try #require(makeBuffer(width: 640, height: 480))
        #expect(FrameFacts(buffer: hd, presentationSize: .zero).matrix == .bt709)
        #expect(FrameFacts(buffer: sd, presentationSize: .zero).matrix == .bt601)
    }

    @Test
    func frameFactsRecognizeHDRFullRangeAndPicturesThatAreNotDrawnRight() throws {
        let pq = try #require(makeBuffer(width: 1920, height: 1080))
        tag(pq, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        #expect(FrameFacts(buffer: pq, presentationSize: .zero).picture.range == .hdr)

        let wide = try #require(makeBuffer(width: 1920, height: 1080))
        tag(wide, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020)
        #expect(FrameFacts(buffer: wide, presentationSize: .zero).picture.range == .hdr)

        let full = try #require(makeBuffer(width: 1280, height: 720, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        #expect(FrameFacts(buffer: full, presentationSize: .zero).fullRange)

        let bgra = try #require(makeBuffer(width: 1280, height: 720, format: kCVPixelFormatType_32BGRA))
        #expect(FrameFacts(buffer: bgra, presentationSize: .zero).picture.refusal == "its frames are not 8-bit 4:2:0")

        // A clip the player turns on its side is drawn upright when its track says so, and refused when it does not.
        let landscape = try #require(makeBuffer(width: 1920, height: 1080))
        let portraitShown = CGSize(width: 1080, height: 1920)
        let quarterTurn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let turned = FrameFacts(buffer: landscape, presentationSize: portraitShown, track: TrackOrientation(transform: quarterTurn))
        #expect(turned.picture.refusal == nil)
        #expect(turned.picture.size == PixelSize(width: 1080, height: 1920))
        #expect(turned.geometry?.orientation.swapsAxes == true)
        #expect(FrameFacts(buffer: landscape, presentationSize: portraitShown).picture.refusal != nil)
        #expect(FrameFacts(buffer: landscape, presentationSize: CGSize(width: 1920, height: 1080)).picture.refusal == nil)

        // A transform that is a scale or a skew cannot be drawn.
        let skewed = TrackOrientation(transform: CGAffineTransform(a: 1, b: 0, c: 0.5, d: 1, tx: 0, ty: 0))
        #expect(FrameFacts(buffer: landscape, presentationSize: .zero, track: skewed).picture.refusal != nil)
    }

    @Test
    func aCleanApertureSmallerThanTheBufferIsCroppedToItsEvenSize() throws {
        let buffer = try #require(makeBuffer(width: 1920, height: 1088))
        let aperture: [String: Any] = [
            kCVImageBufferCleanApertureWidthKey as String: 1920,
            kCVImageBufferCleanApertureHeightKey as String: 1080,
            kCVImageBufferCleanApertureHorizontalOffsetKey as String: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey as String: 0,
        ]
        tag(buffer, kCVImageBufferCleanApertureKey, aperture as CFDictionary)
        let facts = FrameFacts(buffer: buffer, presentationSize: .zero)
        #expect(facts.picture.refusal == nil)
        #expect(facts.picture.size == PixelSize(width: 1920, height: 1080))
        #expect(facts.geometry?.crop.height == 1080)
    }

    @Test
    func anOddSizedFrameLosesItsOddRowAndColumn() throws {
        let buffer = try #require(makeBuffer(width: 853, height: 481))
        let facts = FrameFacts(buffer: buffer, presentationSize: .zero)
        #expect(facts.picture.refusal == nil)
        #expect(facts.picture.size == PixelSize(width: 852, height: 480))
    }

    @Test
    func aPortraitClipKeepsItsMatrixGuessAndInvertsItsPixelShape() throws {
        let sideways = try #require(makeBuffer(width: 1280, height: 720))
        let ratio: [String: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: 4,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 3,
        ]
        tag(sideways, kCVImageBufferPixelAspectRatioKey, ratio as CFDictionary)
        let quarterTurn = TrackOrientation.known(PictureOrientation(swapsAxes: true, flipsAcross: true, flipsDown: false))
        let facts = FrameFacts(buffer: sideways, presentationSize: CGSize(width: 720 * 4.0 / 3.0, height: 1280), track: quarterTurn)
        #expect(facts.matrix == .bt709)
        #expect(abs(facts.picture.pixelAspect - 0.75) < 0.0001)
    }

    @Test
    func pixelAspectComesFromTheBuffer() throws {
        let buffer = try #require(makeBuffer(width: 720, height: 480))
        let ratio: [String: Any] = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: 32,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: 27,
        ]
        tag(buffer, kCVImageBufferPixelAspectRatioKey, ratio as CFDictionary)
        let facts = FrameFacts(buffer: buffer, presentationSize: .zero)
        #expect(abs(facts.picture.pixelAspect - 32.0 / 27.0) < 0.0001)
    }

    @Test
    func updatesStartWithTheCurrentState() async {
        let enhancer = PictureEnhancer()
        var iterator = enhancer.updates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first == EnhanceState.idle)
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func anHDRPictureIsLeftAlone() throws {
        let buffer = try #require(makeBuffer(width: 1280, height: 720))
        tag(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        let enhancer = PictureEnhancer(options: EnhanceOptions(upscaler: .automatic, sharpen: 0.5, deband: 0))
        enhancer.displaySize = CGSize(width: 2560, height: 1440)
        enhancer.attach(to: dummyItem())
        enhancer.setTrackOrientation(.known(.upright))
        enhancer.handle(PulledFrame(readOnly: nil, buffer: buffer, time: .zero), tickTime: 0, deadline: 1)
        #expect(enhancer.state == .unavailable(.highDynamicRange))
        #expect(enhancer.statistics.offered == 0)
        enhancer.detach()
        #expect(enhancer.state == .idle)
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func aHotPhoneGetsThePlainPicture() throws {
        let buffer = try #require(makeBuffer(width: 1280, height: 720))
        let hot = HardwareCapabilities.Power(thermal: .serious, lowPowerMode: false)
        let enhancer = PictureEnhancer(options: EnhanceOptions(upscaler: .automatic, sharpen: 0.5, deband: 0), power: { hot })
        enhancer.displaySize = CGSize(width: 2560, height: 1440)
        enhancer.attach(to: dummyItem())
        enhancer.setTrackOrientation(.known(.upright))
        enhancer.handle(PulledFrame(readOnly: nil, buffer: buffer, time: .zero), tickTime: 0, deadline: 1)
        #expect(enhancer.state == .paused(.powerSaving))
        #expect(enhancer.statistics.offered == 0)
        enhancer.detach()
    }

    @Test(.enabled(if: buffersShare, needsSharing))
    func framesComeOutScaledSharpenedAndDebanded() async throws {
        let buffer = try #require(makeBuffer(width: 640, height: 360))
        let logs = LogLines()
        let enhancer = PictureEnhancer(options: EnhanceOptions(upscaler: .lineArt, sharpen: 0.5, deband: 0.5), logger: logs.logger)
        enhancer.displaySize = CGSize(width: 1280, height: 720)
        enhancer.attach(to: dummyItem())
        enhancer.setTrackOrientation(.known(.upright))
        // The scaler is set up while frames already flow, so wait for the scaled picture, then for three frames of it.
        var baseline: Int?
        try await pump(enhancer, frame: buffer) {
            guard case .running(let plan) = enhancer.state, plan.outputWidth > 640 else { return false }
            if baseline == nil { baseline = enhancer.statistics.shown }
            return enhancer.statistics.shown >= (baseline ?? 0) + 3
        }
        let report = "\(enhancer.statistics) \(enhancer.state)\n\(logs.text)"
        #expect(enhancer.statistics.shown >= 3, Comment(rawValue: report))
        if case .running(let plan) = enhancer.state {
            #expect(plan.outputWidth > 640, Comment(rawValue: report))
            #expect(plan.sourceWidth == 640)
        } else {
            Issue.record(Comment(rawValue: "not running: \(report)"))
        }
        enhancer.options = .off
        #expect(enhancer.state == .idle)
        enhancer.detach()
    }

    @Test(.enabled(if: buffersShare, needsSharing))
    func sharpenAndDebandRunWithoutAScaler() async throws {
        let buffer = try #require(makeBuffer(width: 640, height: 360))
        let logs = LogLines()
        let enhancer = PictureEnhancer(options: EnhanceOptions(upscaler: .off, sharpen: 0.5, deband: 0.5), logger: logs.logger)
        enhancer.displaySize = CGSize(width: 1280, height: 720)
        enhancer.attach(to: dummyItem())
        enhancer.setTrackOrientation(.known(.upright))
        try await pump(enhancer, frame: buffer) { enhancer.statistics.shown >= 3 }
        let report = "\(enhancer.statistics) \(enhancer.state)\n\(logs.text)"
        #expect(enhancer.statistics.shown >= 3, Comment(rawValue: report))
        if case .running(let plan) = enhancer.state {
            #expect(plan.upscaler == nil, Comment(rawValue: report))
            #expect(plan.outputWidth == 640)
        } else {
            Issue.record(Comment(rawValue: "not running: \(report)"))
        }
        enhancer.detach()
    }

    @Test(.enabled(if: buffersShare, needsSharing))
    func denoiseDeblockAndVividRunWithoutAScalerAndAreLogged() async throws {
        let buffer = try #require(makeBuffer(width: 640, height: 360))
        let logs = LogLines()
        let options = EnhanceOptions(upscaler: .off, denoise: 0.5, deblock: 0.5, vivid: 0.5)
        let enhancer = PictureEnhancer(options: options, logger: logs.logger)
        enhancer.displaySize = CGSize(width: 1280, height: 720)
        enhancer.attach(to: dummyItem())
        enhancer.setTrackOrientation(.known(.upright))
        try await pump(enhancer, frame: buffer) { enhancer.statistics.shown >= 4 }
        let report = "\(enhancer.statistics) \(enhancer.state)\n\(logs.text)"
        #expect(enhancer.statistics.shown >= 4, Comment(rawValue: report))
        #expect(enhancer.statistics.failed == 0, Comment(rawValue: report))
        if case .running(let plan) = enhancer.state {
            #expect(plan.denoise == 0.5 && plan.deblock == 0.5 && plan.vivid == 0.5, Comment(rawValue: report))
            #expect(plan.extraPasses == 1)
        } else {
            Issue.record(Comment(rawValue: "not running: \(report)"))
        }
        #expect(logs.text.contains("denoise=0.5"), Comment(rawValue: report))
        #expect(logs.text.contains("deblock=0.5") && logs.text.contains("vivid=0.5"), Comment(rawValue: report))
        // Turning a strength down while playing is a tuning change: the frames keep coming and nothing fails.
        let before = enhancer.statistics.shown
        enhancer.options.denoise = 0
        try await pump(enhancer, frame: buffer) { enhancer.statistics.shown >= before + 3 }
        #expect(enhancer.statistics.shown >= before + 3, Comment(rawValue: report))
        #expect(enhancer.statistics.failed == 0)
        enhancer.detach()
    }

    @Test(.enabled(if: buffersShare, needsSharing))
    func denoiseRunsAfterAScalerAtTheScaledSize() async throws {
        let buffer = try #require(makeBuffer(width: 640, height: 360))
        let logs = LogLines()
        let enhancer = PictureEnhancer(options: EnhanceOptions(upscaler: .lineArt, denoise: 0.7), logger: logs.logger)
        enhancer.displaySize = CGSize(width: 1280, height: 720)
        enhancer.attach(to: dummyItem())
        enhancer.setTrackOrientation(.known(.upright))
        var baseline: Int?
        try await pump(enhancer, frame: buffer) {
            guard case .running(let plan) = enhancer.state, plan.outputWidth > 640 else { return false }
            if baseline == nil { baseline = enhancer.statistics.shown }
            return enhancer.statistics.shown >= (baseline ?? 0) + 3
        }
        let report = "\(enhancer.statistics) \(enhancer.state)\n\(logs.text)"
        #expect(enhancer.statistics.shown >= (baseline ?? 0) + 3, Comment(rawValue: report))
        #expect(enhancer.statistics.failed == 0, Comment(rawValue: report))
        enhancer.detach()
    }
}
