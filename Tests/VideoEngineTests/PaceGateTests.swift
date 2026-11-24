import Testing
@testable import VideoEngine

/// Pacing against a model of AVPlayer on the remux's live playlist: it reloads the playlist every half
/// target duration, loads listed segments at four times real time up to 60 s ahead, and stops loading once
/// the playlist has gone 1.5 target durations without changing, until it changes again (field log,
/// 2026-11-08: it played the 57 s it had and waited at 774.5 s while later segments were listed). Paused, it
/// fails the item at the sixth reload past that (field log, 2026-11-20: -12888 six times, then Playback
/// Stopped, 46 and 50 s after the pause).
struct PaceGateTests {
    private struct Player {
        static let target: Double = 10
        var playhead = 0.0
        /// End of the buffered media from the playhead on.
        var loaded = 0.0
        /// End of the segments in the player's copy of the playlist, and when that copy last changed.
        var listed = 0.0
        var changed = 0.0
        var nextReload = 0.0
        var playing = true
        /// Reloads in a row that found the playlist unchanged for over 1.5 target durations.
        var staleReloads = 0
        var failed = false

        var waiting: Bool { playing && loaded - playhead < 0.05 }

        mutating func step(now: Double, dt: Double, served: Double) {
            guard !failed else { return }
            if now >= nextReload {
                if served != listed {
                    listed = served
                    changed = now
                    staleReloads = 0
                } else if now - changed > 1.5 * Self.target {
                    staleReloads += 1
                    if !playing && staleReloads >= 6 { failed = true }
                }
                nextReload = now + Self.target / 2
            }
            if now - changed <= 1.5 * Self.target, loaded < listed {
                loaded = min(listed, loaded + 4 * dt, playhead + 60)
            }
            if playing { playhead = min(loaded, playhead + dt) }
        }

        mutating func seek(to time: Double) {
            playhead = time
            loaded = time
        }
    }

    /// The remux reading at eight times real time while allowed; a segment is listed once the keyframe
    /// after it, 4 s on, is read.
    private struct Simulation {
        var allows: (_ produced: Double, _ playhead: Double, _ waiting: Bool, _ now: Double) -> Bool
        var reportsWaiting: Bool
        var player = Player()
        var produced = 0.0
        var now = 0.0
        /// Longest time the player has waited for data since `resetWaits()`.
        var longestWait = 0.0
        private var waitingSince: Double?

        init(reportsWaiting: Bool, allows: @escaping (Double, Double, Bool, Double) -> Bool) {
            self.reportsWaiting = reportsWaiting
            self.allows = allows
        }

        var served: Double { (produced / 4).rounded(.down) * 4 }

        mutating func run(for seconds: Double) {
            let dt = 0.1
            for _ in 0..<Int((seconds / dt).rounded()) {
                if allows(produced, player.playhead, reportsWaiting && player.waiting, now) { produced += 8 * dt }
                player.step(now: now, dt: dt, served: served)
                now += dt
                if player.waiting {
                    let since = waitingSince ?? now
                    waitingSince = since
                    longestWait = max(longestWait, now - since)
                } else {
                    waitingSince = nil
                }
            }
        }

        mutating func resetWaits() {
            longestWait = 0
            waitingSince = nil
        }
    }

    /// `clock: false` holds the gate's clock still: production keeps step with the playhead alone.
    private static func gated(clock: Bool = true) -> (Double, Double, Bool, Double) -> Bool {
        var gate = PaceGate(lead: 75, headroom: Player.target)
        return { gate.allows(produced: $0, playhead: $1, playerWaiting: $2, now: clock ? $3 : 0) }
    }

    /// The field case, with only the playhead reported by the consumer.
    @Test func backwardSeekWithinTheRunKeepsPlaying() {
        var paced = Simulation(reportsWaiting: false, allows: Self.gated())
        paced.run(for: 300)
        let target = paced.player.playhead - 100
        paced.player.seek(to: target)
        paced.resetWaits()
        paced.run(for: 600)
        print("pace: after a 100 s backward seek, longest wait \(paced.longestWait) s, played \(paced.player.playhead - target) s of 600")
        #expect(paced.longestWait < 2)
        #expect(paced.player.playhead - target > 595)

        // The rule it replaces: wait while more than the lead ahead of the playhead.
        var old = Simulation(reportsWaiting: false) { produced, playhead, _, _ in produced - playhead <= 75 }
        old.run(for: 300)
        old.player.seek(to: old.player.playhead - 100)
        old.resetWaits()
        old.run(for: 600)
        #expect(old.longestWait > 500)
    }

    /// Seeking back again and again, as a scrubbing viewer does, never leaves production waiting for a
    /// playhead that is far behind what it has produced.
    @Test func repeatedBackwardSeeksKeepPlaying() {
        var sim = Simulation(reportsWaiting: false, allows: Self.gated())
        sim.run(for: 400)
        for step in [90.0, 40.0, 150.0] {
            sim.player.seek(to: max(0, sim.player.playhead - step))
            sim.resetWaits()
            let from = sim.player.playhead
            sim.run(for: 120)
            #expect(sim.longestWait < 2)
            #expect(sim.player.playhead - from > 115)
        }
    }

    /// Paused in Picture in Picture by an audio interruption (field log, 2026-11-20), then resumed with the
    /// buffer dropped.
    @Test func aLongPauseKeepsTheItemAliveAndResumesPlaying() {
        var sim = Simulation(reportsWaiting: true, allows: Self.gated())
        sim.run(for: 200)
        sim.player.playing = false
        sim.run(for: 600)
        print("pace: paused 600 s, produced \(sim.produced - sim.player.playhead) s ahead")
        #expect(!sim.player.failed)
        // At real time, no faster: over a pause, no more than the pause's length is downloaded ahead.
        #expect(sim.produced - sim.player.playhead <= 75 + 600 + Player.target + 1)
        sim.player.loaded = sim.player.playhead
        sim.player.playing = true
        let resumedAt = sim.player.playhead
        sim.resetWaits()
        sim.run(for: 120)
        print("pace: resumed with no buffer, longest wait \(sim.longestWait) s")
        #expect(sim.longestWait < 6)
        #expect(sim.player.playhead - resumedAt > 110)

        // Keeping step with the playhead alone holds the playlist still, and the paused item fails.
        var playheadOnly = Simulation(reportsWaiting: true, allows: Self.gated(clock: false))
        playheadOnly.run(for: 200)
        playheadOnly.player.playing = false
        playheadOnly.run(for: 60)
        #expect(playheadOnly.player.failed)
    }

    @Test func leadDoublesOverAFarOrNarrowLink() {
        #expect(PaceGate.lead(base: 75, latency: 0.01, bytesPerSecond: 10e6, mediaBytesPerSecond: 1.4e6) == 75)
        #expect(PaceGate.lead(base: 75, latency: 0.12, bytesPerSecond: 10e6, mediaBytesPerSecond: 1.4e6) == 150)
        #expect(PaceGate.lead(base: 75, latency: 0.01, bytesPerSecond: 2e6, mediaBytesPerSecond: 1.4e6) == 150)
    }
}
