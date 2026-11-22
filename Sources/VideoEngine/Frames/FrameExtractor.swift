import CoreGraphics
import Foundation
import os

/// One picture pulled out of a video.
public struct ExtractedFrame: @unchecked Sendable {
    /// The picture: 8 bits per channel, shrunk to fit the requested width and never enlarged.
    public let image: CGImage
    /// Where the picture sits in the video, in seconds from its start: the keyframe at or before the time asked
    /// for. It is normally a little before the request, and after it only when the keyframe is shown later than
    /// it is stored.
    public let actualSeconds: Double
    /// Bytes the source returned to the demuxer during this call. The first call also pays for opening the video.
    public let bytesRead: Int64
}

/// Pulls single pictures out of a video, for thumbnails and scrub previews, from any `ByteRangeSource`.
///
/// A call seeks to the keyframe at or before the time asked for and decodes just that picture. Nothing is decoded
/// forward, so the picture can be up to one keyframe interval earlier than the request; `actualSeconds` says where
/// it really is. The first call opens the video and the open demuxer and decoder are reused after that, so a scrub
/// costs one keyframe per call.
///
/// Calls run one at a time, in order, on a queue of their own at `utility` priority. A call whose task is cancelled
/// throws `CancellationError` at once and its unfinished work is dropped, queued or running. The source is never
/// cancelled for it, because cancelling a source is permanent: the source stays usable, and whoever made it owns
/// it. A call stuck in the source's own read (a dead network) holds the queue until that read returns, and the
/// owner can end it by cancelling the source.
///
/// Decoding uses VideoToolbox when the device and the codec allow it, and FFmpeg's decoders otherwise (libdav1d for
/// AV1); the Simulator always uses FFmpeg. The scaler reads the video's own colour matrix, picture shape (pixel
/// aspect ratio) and 90-degree rotation. HDR is not tone mapped: HDR10 and HLG pictures come out as plain SDR
/// (flat but recognisable), and Dolby Vision profile 5 colours are not corrected.
///
/// Limits, whatever the caller asks for: the picture is at most 3840 pixels wide and 3840 x 2160 pixels in all;
/// videos whose pictures are larger than 8192 x 4608 are refused; a call that makes no progress for 30 seconds
/// throws `VideoEngineError.timedOut` (time the source reports as an outage does not count); and a keyframe must
/// turn up within 64 MiB of reading after the seek.
public final class FrameExtractor: Sendable {
    private let worker: FrameWorker

    /// An extractor for `source`. Nothing is read until the first `frame(at:maxWidth:)`.
    public init(source: any ByteRangeSource, logger: EngineLogger = .silent) {
        worker = FrameWorker(source: source, logger: logger)
    }

    deinit { worker.shutdown() }

    /// The picture at the keyframe at or before `seconds` (movie time, clamped to 0 or later), shrunk so that it is
    /// at most `maxWidth` pixels wide (capped at 3840) and never enlarged. Throws `CancellationError` when the
    /// calling task is cancelled.
    public func frame(at seconds: Double, maxWidth: Int) async throws -> ExtractedFrame {
        try Task.checkCancellation()
        guard seconds.isFinite else { throw VideoEngineError.failure("frame time", FF.einval) }
        guard maxWidth > 0 else { throw VideoEngineError.failure("frame width", FF.einval) }
        let job = FrameJob(
            seconds: min(max(0, seconds), FrameLimits.maxSeconds), maxWidth: min(maxWidth, FrameLimits.maxWidth)
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ExtractedFrame, any Error>) in
                if job.install(continuation) { worker.submit(job) }
            }
        } onCancel: {
            job.cancel()
        }
    }
}

/// What the extractor allows itself, whatever the caller asks for.
enum FrameLimits {
    /// The widest picture it returns.
    static let maxWidth = 3840
    /// The most pixels in a returned picture (4K UHD).
    static let outputPixels = 3840 * 2160
    /// The most pixels in a picture it agrees to decode (8K).
    static let sourcePixels = 8192 * 4608
    /// Seconds a call may go without progress; the first call includes opening the video.
    static let timeout: TimeInterval = 30
    /// Bytes read after a seek while looking for a keyframe before the call gives up.
    static let keyframeSearchBytes = 64 << 20
    /// The latest time a call can ask for, which keeps the seek target inside 64 bits at any time base.
    static let maxSeconds: Double = 10_000_000
}

/// One call to `frame(at:maxWidth:)`, shared by the caller's task and the worker queue. Every call ends exactly
/// once: the continuation is taken out under the lock by whichever of the worker or the cancellation gets there first.
final class FrameJob: @unchecked Sendable {
    let seconds: Double
    let maxWidth: Int

    private struct State: Sendable {
        var continuation: CheckedContinuation<ExtractedFrame, any Error>?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(seconds: Double, maxWidth: Int) {
        self.seconds = seconds
        self.maxWidth = maxWidth
    }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    /// Parks the caller's continuation until the worker answers. False when the task was cancelled first and the
    /// continuation has already been ended, so there is nothing left to run.
    func install(_ continuation: CheckedContinuation<ExtractedFrame, any Error>) -> Bool {
        let cancelled = state.withLock { state -> Bool in
            if !state.cancelled { state.continuation = continuation }
            return state.cancelled
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        return !cancelled
    }

    /// Ends the caller's wait now, from the task's cancellation handler on whatever thread. The worker notices the
    /// flag at its next step and stops.
    func cancel() {
        take(cancelling: true)?.resume(throwing: CancellationError())
    }

    /// The worker's answer; dropped when the caller has already left.
    func finish(_ result: Result<ExtractedFrame, any Error>) {
        take(cancelling: false)?.resume(with: result)
    }

    private func take(cancelling: Bool) -> CheckedContinuation<ExtractedFrame, any Error>? {
        state.withLock { state -> CheckedContinuation<ExtractedFrame, any Error>? in
            if cancelling { state.cancelled = true }
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
    }
}

/// The caller's source with two additions: it counts the bytes the demuxer gets during a call, and it fails the
/// reads of a cancelled call. Failing the read stops FFmpeg without touching the caller's source, whose `cancel()`
/// is permanent: a cancelled thumbnail must not kill a source that playback may share.
private final class MeteredSource: ByteRangeSource {
    private struct State: Sendable {
        var job: FrameJob?
        var bytes: Int64 = 0
    }

    private let base: any ByteRangeSource
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(base: any ByteRangeSource) {
        self.base = base
    }

    /// Bytes handed to the demuxer since `begin`.
    var bytes: Int64 { state.withLock { $0.bytes } }

    func begin(_ job: FrameJob) {
        state.withLock {
            $0.job = job
            $0.bytes = 0
        }
    }

    func end() {
        state.withLock { $0.job = nil }
    }

    var logName: String { base.logName }
    var bytesPerSecond: Double? { base.bytesPerSecond }
    var latency: TimeInterval? { base.latency }
    var isFetching: Bool { base.isFetching }
    var isReconnecting: Bool { base.isReconnecting }
    var outageSeconds: TimeInterval { base.outageSeconds }

    func length() throws -> Int64? {
        try checkCancelled()
        return try base.length()
    }

    func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        try checkCancelled()
        let count = try base.read(at: offset, into: buffer)
        state.withLock { $0.bytes += Int64(count) }
        try checkCancelled()
        return count
    }

    /// Passed through for the protocol; the extractor never calls it.
    func cancel() { base.cancel() }

    private func checkCancelled() throws {
        try state.withLock { $0.job }?.checkCancelled()
    }
}

/// The extractor's engine: one serial queue, the open video, and the books of the call being served.
private final class FrameWorker: @unchecked Sendable {
    private let metered: MeteredSource
    private let control = RunControl(timeout: FrameLimits.timeout)
    private let logger: EngineLogger
    private let queue = DispatchQueue(label: "videoengine-frames", qos: .utility)
    /// The open video. Touched only on `queue`.
    private var session: FrameSession?

    init(source: any ByteRangeSource, logger: EngineLogger) {
        metered = MeteredSource(base: source)
        self.logger = logger
    }

    func submit(_ job: FrameJob) {
        queue.async { self.run(job) }
    }

    /// Stops what is running and lets go of the video once the queue gets to it. The source is left alone: it is
    /// the caller's.
    func shutdown() {
        control.stop()
        queue.async { self.session = nil }
    }

    private func run(_ job: FrameJob) {
        guard !job.isCancelled, !control.isStopped else {
            job.finish(.failure(CancellationError()))
            return
        }
        metered.begin(job)
        defer { metered.end() }
        do {
            let frame = try extract(job)
            job.finish(.success(frame))
        } catch {
            let cancelled = job.isCancelled || control.isStopped
            if !cancelled {
                logger.event("frames-fail", [("source", metered.logName), ("error", String(describing: error))])
            }
            job.finish(.failure(cancelled ? CancellationError() : error))
        }
    }

    private func extract(_ job: FrameJob) throws -> ExtractedFrame {
        control.extendDeadline(by: FrameLimits.timeout)
        let session = try openSession()
        let picked = try session.frame(at: job.seconds, maxWidth: job.maxWidth, job: job)
        return ExtractedFrame(image: picked.image, actualSeconds: picked.seconds, bytesRead: metered.bytes)
    }

    /// The open video: opened on the first call, and again after an open that failed or was cancelled. A video that
    /// is open stays open when a later call fails or is cancelled, because the next call seeks anyway.
    private func openSession() throws -> FrameSession {
        if let session {
            // An interrupted call may have left an error behind; it must not fail this one.
            session.input.clearError()
            return session
        }
        let opened = try FrameSession(source: metered, control: control, logger: logger)
        session = opened
        return opened
    }
}
