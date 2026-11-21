import Foundation

/// When a paced run may read on. Production waits once it is `lead` seconds ahead of the playhead, except
/// where waiting would leave the player waiting on it:
///
/// - While the player waits for data, production goes on: whatever the player waits for, more output is
///   what ends the wait.
/// - Past the lead, production keeps step with the playhead or the clock, whichever has moved further,
///   instead of stopping until the playhead catches up. AVPlayer stops loading the segments of a live
///   playlist that has not grown for 1.5 target durations, listed ones included: after the playhead moved
///   back 100 s within a run, it played the 57 s it had loaded and then waited for good, while production
///   waited for the playhead (field log, 2026-11-08). Paused, it fails the item instead: six reloads of an
///   unchanged playlist, 46 to 50 s after the pause, ended a paused Picture in Picture with -12888 twice
///   in one evening (field log, 2026-11-20). Keeping step with the clock adds a segment for each target
///   duration that passes, so the playlist grows whether the picture moves or not; a move backwards starts
///   the step again from the new position.
struct PaceGate: Sendable {
    var lead: TimeInterval
    /// How far production may run past the step, one target duration, so the next segment is always under
    /// way.
    let headroom: TimeInterval
    /// Playhead, production and the clock when the run went past the lead, or when the playhead last moved
    /// back.
    private var mark: (playhead: TimeInterval, produced: TimeInterval, at: TimeInterval)?
    private var lastPlayhead: TimeInterval = 0

    init(lead: TimeInterval, headroom: TimeInterval) {
        self.lead = lead
        self.headroom = headroom
    }

    /// - Parameter now: a monotonic clock, in seconds.
    mutating func allows(produced: TimeInterval, playhead: TimeInterval, playerWaiting: Bool, now: TimeInterval) -> Bool {
        defer { lastPlayhead = playhead }
        if playerWaiting || produced - playhead <= lead {
            mark = nil
            return true
        }
        if let mark, playhead >= lastPlayhead {
            return produced - mark.produced <= max(playhead - mark.playhead, now - mark.at) + headroom
        }
        mark = (playhead: playhead, produced: produced, at: now)
        return true
    }

    /// Twice `base` over a far link (100 ms or more to the first byte) or one with less than the media's
    /// rate to spare, where refilling after a dropout is slow, so more of the dropout is ridden out from
    /// output already made.
    static func lead(
        base: TimeInterval, latency: TimeInterval?, bytesPerSecond: Double?, mediaBytesPerSecond: Double?
    ) -> TimeInterval {
        if let latency, latency >= 0.1 { return base * 2 }
        if let bytesPerSecond, let mediaBytesPerSecond, bytesPerSecond < mediaBytesPerSecond * 2 { return base * 2 }
        return base
    }
}
