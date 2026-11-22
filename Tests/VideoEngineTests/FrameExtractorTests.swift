import CoreGraphics
import Foundation
import os
import Testing
@testable import VideoEngine

struct FrameExtractorTests {
    /// The HEVC 10-bit fixture is 160x96 with keyframes at 0.007 s and 1.007 s, 2 s long.
    private static let hevc = "hevc10-opus-srt.mkv"

    private static func extractor(_ name: String) throws -> (FrameExtractor, CountingSource) {
        let source = try CountingSource(Fixture.url(name))
        return (FrameExtractor(source: source), source)
    }

    @Test func returnsTheKeyframeAtOrBeforeTheTarget() async throws {
        let (extractor, _) = try Self.extractor(Self.hevc)
        let result = try await extractor.frame(at: 1.5, maxWidth: 160)
        let image: CGImage = result.image
        let seconds: Double = result.actualSeconds
        let bytes: Int64 = result.bytesRead
        #expect(image.width > 0 && image.height > 0)
        #expect(seconds <= 1.5)
        #expect(abs(seconds - 1.007) < 0.05)
        #expect(bytes > 0)
    }

    @Test func landsOnTheFirstKeyframeBeforeTheSecondOne() async throws {
        let (extractor, _) = try Self.extractor(Self.hevc)
        let result = try await extractor.frame(at: 0.5, maxWidth: 160)
        #expect(result.actualSeconds <= 0.5)
        #expect(abs(result.actualSeconds - 0.007) < 0.05)
    }

    @Test func picksTheKeyframeBeforeATargetInAnH264File() async throws {
        let (extractor, _) = try Self.extractor("h264-aac-60s.mkv")
        let result = try await extractor.frame(at: 10.5, maxWidth: 96)
        #expect(result.actualSeconds <= 10.5)
        #expect(abs(result.actualSeconds - 10.064) < 0.05)
    }

    @Test func scalesDownToMaxWidthKeepingTheAspectRatio() async throws {
        let (extractor, _) = try Self.extractor(Self.hevc)
        let result = try await extractor.frame(at: 1.5, maxWidth: 80)
        #expect(result.image.width <= 80)
        #expect(result.image.width >= 79)
        #expect(abs(result.image.height - 48) <= 1)
        let pixels = try Pixels(result.image)
        #expect(pixels.nonBlackCount > pixels.count / 2)
        #expect(pixels.distinctLuma > 8)
    }

    @Test func neverScalesUp() async throws {
        let (extractor, _) = try Self.extractor(Self.hevc)
        let result = try await extractor.frame(at: 1.5, maxWidth: 1000)
        #expect(result.image.width == 160)
        #expect(result.image.height == 96)
        let pixels = try Pixels(result.image)
        #expect(pixels.nonBlackCount > pixels.count / 2)
    }

    /// The second call reuses the open demuxer: the container header at byte zero is not read again, and
    /// each call counts only the bytes the source supplied for it.
    @Test func opensTheSourceOnceAndReusesItAcrossCalls() async throws {
        let (extractor, source) = try Self.extractor(Self.hevc)
        let first = try await extractor.frame(at: 0.5, maxWidth: 80)
        let afterFirst = source.snapshot()
        #expect(afterFirst.headerReads >= 1)
        #expect(first.bytesRead > 0)
        #expect(first.bytesRead <= afterFirst.bytes)

        let second = try await extractor.frame(at: 1.5, maxWidth: 80)
        let afterSecond = source.snapshot()
        #expect(afterSecond.headerReads == afterFirst.headerReads)
        #expect(second.bytesRead == afterSecond.bytes - afterFirst.bytes)
        #expect(abs(second.actualSeconds - 1.007) < 0.05)
        #expect(abs(first.actualSeconds - 0.007) < 0.05)

        // The same position again still decodes the same frame.
        let again = try await extractor.frame(at: 1.5, maxWidth: 80)
        #expect(again.actualSeconds == second.actualSeconds)
        #expect(source.snapshot().headerReads == afterFirst.headerReads)
    }

    @Test func aCancelledTaskThrowsCancellationError() async throws {
        let (extractor, _) = try Self.extractor(Self.hevc)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await extractor.frame(at: 1.5, maxWidth: 80)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// A cancelled call must end without poisoning the source: the gated read is released right after
    /// the cancel, the call throws, and the same extractor then decodes the next request.
    @Test func cancellingWhileTheSourceIsStalledEndsTheCallAndLeavesTheExtractorUsable() async throws {
        let source = try StalledSource(Fixture.url(Self.hevc))
        let extractor = FrameExtractor(source: source)
        let task = Task { try await extractor.frame(at: 1.5, maxWidth: 80) }
        defer { source.release() }
        let deadline = ContinuousClock.now + .seconds(30)
        while !source.isWaiting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(source.isWaiting)

        task.cancel()
        source.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(source.cancelCalls == 0)

        let later = try await extractor.frame(at: 1.5, maxWidth: 80)
        #expect(later.actualSeconds <= 1.5)
        #expect(abs(later.actualSeconds - 1.007) < 0.05)
        #expect(later.image.width > 0)
        #expect(source.cancelCalls == 0)
    }
}

/// A local file that counts what the extractor asks of it.
private final class CountingSource: ByteRangeSource {
    struct Counts {
        var headerReads = 0
        var bytes: Int64 = 0
    }

    private let base: FileRangeSource
    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    init(_ url: URL) throws { base = try FileRangeSource(fileURL: url) }

    var logName: String { "counting-" + base.logName }

    func snapshot() -> Counts { counts.withLock { $0 } }

    func length() throws -> Int64? { try base.length() }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let count = try base.read(at: offset, into: buffer)
        counts.withLock {
            if offset == 0 { $0.headerReads += 1 }
            $0.bytes += Int64(count)
        }
        return count
    }

    func cancel() { base.cancel() }
}

/// A local file whose first nonempty read, at whatever offset, does not return until `release()`: a link
/// that stalls while the extractor works. After the release every read is served normally. `cancel()`
/// poisons the source for good, as the real ones do, and is counted so a test can show it was never called.
private final class StalledSource: ByteRangeSource {
    private struct Gate {
        var gated = false
        var waiting = false
        var released = false
        var cancelCalls = 0
    }

    private let base: FileRangeSource
    private let gate = OSAllocatedUnfairLock(initialState: Gate())
    private let condition = NSCondition()

    init(_ url: URL) throws { base = try FileRangeSource(fileURL: url) }

    var logName: String { "stalled-" + base.logName }
    var isWaiting: Bool { gate.withLock { $0.waiting } }
    var cancelCalls: Int { gate.withLock { $0.cancelCalls } }
    func length() throws -> Int64? { try base.length() }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let mustWait = buffer.count > 0 && gate.withLock { state in
            guard !state.gated else { return false }
            state.gated = true
            state.waiting = true
            return true
        }
        if mustWait {
            condition.lock()
            while !gate.withLock({ $0.released }) { condition.wait() }
            condition.unlock()
        }
        return try base.read(at: offset, into: buffer)
    }

    func cancel() {
        gate.withLock { $0.cancelCalls += 1 }
        base.cancel()
    }

    /// Lets the stalled read, and every later one, through.
    func release() {
        gate.withLock { $0.released = true }
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}

/// RGBA bytes of an image, for checking that a frame is not blank.
private struct Pixels {
    let count: Int
    let nonBlackCount: Int
    let distinctLuma: Int

    init(_ image: CGImage) throws {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CocoaError(.fileReadUnknown) }
        var nonBlack = 0
        var lumas = Set<UInt8>()
        for pixel in 0..<(width * height) {
            let r = data[pixel * 4], g = data[pixel * 4 + 1], b = data[pixel * 4 + 2]
            if r | g | b > 8 { nonBlack += 1 }
            lumas.insert(UInt8((Int(r) + Int(g) + Int(b)) / 3))
        }
        count = width * height
        nonBlackCount = nonBlack
        distinctLuma = lumas.count
    }
}
