import Foundation
import LoopbackHLS
import os

/// What `RemuxSession.seekReusing(to:)` decided (v2.2.0).
public struct RemuxSeek: Sendable, Equatable {
    /// The playlist URL to play: the current run's when `reused`, a new run's otherwise.
    public var url: URL
    /// Where to seek the item, in seconds on the run's output timeline, when `reused`: the target minus the
    /// run's timeline origin. Nil for a new run, whose origin arrives as `.timeline(origin:)`; the item is
    /// then replaced and positioned at the target minus that origin, as after `seek(to:)`.
    public var itemTime: TimeInterval?
    /// True when the target was already produced: the run goes on, keep the item and seek it to `itemTime`.
    public var reused: Bool

    public init(url: URL, itemTime: TimeInterval?, reused: Bool) {
        self.url = url
        self.itemTime = itemTime
        self.reused = reused
    }
}

/// Plays a source AVPlayer cannot open directly (Matroska, for instance) by copying its audio and video
/// into a fragmented MP4 that grows on disk and is served as HLS from 127.0.0.1. No re-encoding.
///
/// `start(at:)` returns the playlist URL for AVPlayer. Each `seek(to:)` begins a new run at that point
/// with its own URL. `stop()` ends the run and deletes its file; it also runs on deinit.
public final class RemuxSession: Sendable {
    /// Forward buffer for the AVPlayerItem: the playlist grows in real time, so a larger buffer only
    /// makes AVPlayer wait for fragments that do not exist yet.
    public static let recommendedForwardBufferDuration: TimeInterval = 15

    /// Every run's events. Finishes after `stop()`.
    public let events: AsyncStream<RemuxEvent>

    private struct Active: Sendable {
        let run: RemuxRun
        let server: LoopbackServer
        let url: URL
    }

    private struct State: Sendable {
        var active: Active?
        var stopped = false
        var playerWaiting = false
    }

    private let continuation: AsyncStream<RemuxEvent>.Continuation
    private let makeSource: @Sendable () throws -> any ByteRangeSource
    private let options: RemuxOptions
    private let logger: EngineLogger
    private let state = OSAllocatedUnfairLock(initialState: State())

    public convenience init(
        url: URL,
        headers: [String: String] = [:],
        readAheadBytes: Int = 4 << 20,
        options: RemuxOptions = RemuxOptions(),
        logger: EngineLogger = .silent
    ) {
        self.init(
            sourceFactory: { try ByteRangeSources.make(for: url, headers: headers, readAheadBytes: readAheadBytes) },
            options: options,
            logger: logger
        )
    }

    /// - Parameter sourceFactory: called once per run, on the run's thread.
    public init(
        sourceFactory: @escaping @Sendable () throws -> any ByteRangeSource,
        options: RemuxOptions = RemuxOptions(),
        logger: EngineLogger = .silent
    ) {
        (events, continuation) = AsyncStream.makeStream(of: RemuxEvent.self, bufferingPolicy: .bufferingNewest(32))
        self.makeSource = sourceFactory
        self.options = options
        self.logger = logger
    }

    deinit { stop() }

    /// The current run's progress.
    public var progress: RemuxProgress {
        state.withLock { $0.active?.run }?.progress ?? RemuxProgress()
    }

    /// Movie time at which the current run's output timeline starts, once its first packets are read;
    /// also sent as `.timeline(origin:)`. A position `t` on the output timeline is movie time `t + origin`.
    public var timelineOrigin: TimeInterval? {
        state.withLock { $0.active?.run }?.origin
    }

    /// The current run's subtitles, once the source is open: text ones are renditions of the multivariant
    /// playlist that AVPlayer offers by name; picture ones carry an overlay track for the app to draw.
    public var subtitleStreams: [RemuxSubtitle] {
        state.withLock { $0.active?.run }?.subtitles ?? []
    }

    /// Starts the first run and returns its playlist URL; returns the current URL when a run exists.
    /// Throws `CancellationError` after `stop()`.
    public func start(at time: TimeInterval = 0) async throws -> URL {
        try await launch(at: time, replacingCurrent: false)
    }

    /// Replaces the current run with one that starts at the keyframe at or before `time` (movie seconds)
    /// and returns its URL. The new output's timeline starts at that run's origin, so the item is
    /// positioned at `time - origin` to land on `time` exactly.
    public func seek(to time: TimeInterval) async throws -> URL {
        try await launch(at: time, replacingCurrent: true)
    }

    /// `seek(to:)` that keeps the current run when the target is already in what it produced (v2.2.0). A
    /// target inside the run's sealed segments, at or after its origin, needs no new run: the item is seeked
    /// to `itemTime` on the same URL, with nothing downloaded again, and pacing follows the playhead as it
    /// moves back. Any other target, including one past what the run has sealed, or after a failed run,
    /// behaves as `seek(to:)`. Audio and subtitle choices are fixed by `options`, so a run's output always
    /// matches them. Design after AetherEngine's documented feature; no code taken.
    public func seekReusing(to time: TimeInterval) async throws -> RemuxSeek {
        if let reuse = try reusableSeek(to: time) { return reuse }
        return RemuxSeek(url: try await launch(at: time, replacingCurrent: true), itemTime: nil, reused: false)
    }

    /// The player's position on the current run's timeline; production waits once it is
    /// `paceLeadSeconds` ahead of it, then keeps step with it.
    public func updatePlayhead(_ seconds: TimeInterval) {
        state.withLock { $0.active?.run }?.setPlayhead(seconds)
    }

    /// Whether the player is waiting for data (`AVPlayer.timeControlStatus` is
    /// `.waitingToPlayAtSpecifiedRate`). Production never waits for the playhead while the player waits for
    /// production. Carries over to later runs.
    public func setPlayerWaiting(_ waiting: Bool) {
        state.withLock { state in
            state.playerWaiting = waiting
            state.active?.run.setPlayerWaiting(waiting)
        }
    }

    /// Ends the current run, deletes its file and finishes `events`. Idempotent.
    public func stop() {
        let active = state.withLock { state -> Active? in
            state.stopped = true
            defer { state.active = nil }
            return state.active
        }
        if let active { end(active) }
        continuation.finish()
    }

    /// Deletes files an earlier process left behind. Call once at launch, before any session starts.
    public static func sweepStaleFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        prefixes: [String] = [RemuxOptions().tempFilePrefix]
    ) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where prefixes.contains(where: { name.hasPrefix($0) }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func launch(at time: TimeInterval, replacingCurrent: Bool) async throws -> URL {
        if !replacingCurrent, let url = try currentURL() { return url }
        let fileURL = options.tempDirectory.appendingPathComponent("\(options.tempFilePrefix)\(UUID().uuidString).mp4")
        let run = RemuxRun(fileURL: fileURL, startTime: max(0, time), openTimeout: options.openTimeout, logger: logger)
        // A copy, so the server's log closure does not keep the session alive.
        let loopLogger = logger
        let server = LoopbackServer(routes: [
            LoopbackRoute(path: "/master.m3u8", .playlist({ run.multivariantPlaylist() })),
            LoopbackRoute(path: "/index.m3u8", .playlist({ run.playlist() })),
            LoopbackRoute(path: "/subs/", .generated({ run.subtitleResponse($0) })),
            LoopbackRoute(path: "/media.mp4", .growingFile(
                fileURL, availableBytes: { run.bytesWritten }, isComplete: { run.isComplete }, contentType: "video/mp4"
            )),
        ], queueLabel: "videoengine-remux", log: { loopLogger.loopback($0, $1) })
        EngineDiagnostics.track(server)
        let base: URL
        do {
            base = try await server.start()
        } catch {
            throw VideoEngineError.serverBindFailed
        }
        let playlist = options.multivariantPlaylist ? "master.m3u8" : "index.m3u8"
        let active = Active(run: run, server: server, url: base.appendingPathComponent(playlist))
        let swap = state.withLock { state -> (accepted: Bool, previous: Active?, current: URL?) in
            if state.stopped { return (false, nil, nil) }
            if !replacingCurrent, let current = state.active { return (false, nil, current.url) }
            defer { state.active = active }
            run.setPlayerWaiting(state.playerWaiting)
            return (true, state.active, nil)
        }
        guard swap.accepted else {
            server.stop()
            if let url = swap.current { return url }
            throw CancellationError()
        }
        if let previous = swap.previous { end(previous) }
        logger.event("remux-start", [("at", String(format: "%.1f", run.startTime))])

        let continuation = self.continuation
        let remuxer = Remuxer(
            run: run, makeSource: makeSource, options: options, logger: logger,
            contentChanged: { server.contentChanged() },
            emit: { continuation.yield($0) }
        )
        let thread = Thread { remuxer.start() }
        thread.name = "videoengine-remux"
        thread.qualityOfService = .userInitiated
        thread.start()
        return active.url
    }

    /// Where on the output timeline a movie time lies when a run with this origin has sealed segments for
    /// `sealedDuration` seconds, or nil when it lies before the run's start or past what it has sealed.
    static func reusableItemTime(for time: TimeInterval, origin: TimeInterval, sealedDuration: TimeInterval) -> TimeInterval? {
        let itemTime = time - origin
        return itemTime >= 0 && itemTime < sealedDuration ? itemTime : nil
    }

    private func reusableSeek(to time: TimeInterval) throws -> RemuxSeek? {
        let active = try state.withLock { state -> Active? in
            if state.stopped { throw CancellationError() }
            return state.active
        }
        guard let active, !active.run.isFailed, let origin = active.run.origin, let index = active.run.index else { return nil }
        let sealed = index.sealedDuration
        guard let itemTime = Self.reusableItemTime(for: time, origin: origin, sealedDuration: sealed) else { return nil }
        // The next playhead update would say the same; pacing need not wait for it to see the move.
        active.run.setPlayhead(itemTime)
        logger.event("remux-seek-reuse", [
            ("to", String(format: "%.1f", time)), ("item", String(format: "%.1f", itemTime)),
            ("sealed", String(format: "%.1f", sealed)),
        ])
        return RemuxSeek(url: active.url, itemTime: itemTime, reused: true)
    }

    private func currentURL() throws -> URL? {
        try state.withLock { state -> URL? in
            if state.stopped { throw CancellationError() }
            return state.active?.url
        }
    }

    /// Stops a run that is being replaced or shut down. Its thread exits at the next packet or read.
    private func end(_ active: Active) {
        active.run.stop()
        if active.run.claimTerminal() { continuation.yield(.stopped(active.run.progress)) }
        active.server.stop()
        try? FileManager.default.removeItem(at: active.run.fileURL)
    }
}
