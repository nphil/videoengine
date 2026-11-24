import Foundation
import os
import Testing
@testable import VideoEngine

/// Whole runs with the v2.2.0 audio options: what the master playlist declares for the audio, and that
/// the run reaches its end.
struct AudioRemuxTests {
    private struct Outcome {
        var master: String
        var audioPlans: [String]
    }

    private func remux(_ fixture: URL, audio: AudioPolicy) async throws -> Outcome {
        var options = RemuxOptions()
        options.audio = audio
        let plans = OSAllocatedUnfairLock(initialState: [String]())
        let logger = EngineLogger(
            event: { tag, fields in
                guard tag == "remux-plan", let plan = fields.first(where: { $0.0 == "audio" })?.1 else { return }
                plans.withLock { $0.append(plan) }
            },
            message: { _ in }
        )
        let session = RemuxSession(sourceFactory: { try FileRangeSource(fileURL: fixture) }, options: options, logger: logger)
        defer { session.stop() }
        // Only catches a hung run: simulator hosts have frozen test processes for over 10 s.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            session.stop()
        }
        defer { watchdog.cancel() }
        let playlistURL = try await session.start()
        var finished = false
        events: for await event in session.events {
            switch event {
            case .finished:
                finished = true
                break events
            case .failed(let error, _):
                Issue.record("remux failed: \(error)")
                break events
            case .stopped:
                break events
            default:
                continue
            }
        }
        #expect(finished)
        let (master, _) = try await URLSession.shared.data(from: playlistURL)
        return Outcome(master: String(decoding: master, as: UTF8.self), audioPlans: plans.withLock { $0 })
    }

    @Test func surroundThatIsNotCopiedBecomesEAC3WhenAsked() async throws {
        let source = Fixture.temporaryURL(".mkv")
        defer { try? FileManager.default.removeItem(at: source) }
        try SyntheticAudio.writeSurroundMatroska(to: source, seconds: 3)

        // PCM 5.1 is not copied: AAC unless the policy asks for E-AC-3.
        let aac = try await remux(source, audio: AudioPolicy())
        #expect(aac.master.contains(",mp4a.40.2\""), "\(aac.master)")

        var policy = AudioPolicy()
        policy.surroundCodec = .eac3
        let eac3 = try await remux(source, audio: policy)
        #expect(eac3.master.contains(",ec-3\""), "\(eac3.master)")
        #expect(eac3.audioPlans.count == 1)
        #expect(eac3.audioPlans.first?.contains("eac3") == true)
    }

    @Test func shapingReencodesAudioThatWouldHaveBeenCopied() async throws {
        let fixture = try Fixture.url("h264-aac.mkv")
        let copied = try await remux(fixture, audio: AudioPolicy())
        #expect(copied.audioPlans.count == 1)
        #expect(copied.audioPlans.first?.contains("copy") == true)

        var policy = AudioPolicy()
        policy.shaping = AudioShaping(delay: 0.2, dialogueLift: 4, nightMode: true)
        let shaped = try await remux(fixture, audio: policy)
        #expect(shaped.audioPlans.count == 1)
        #expect(shaped.audioPlans.first?.contains("reencode") == true)
        #expect(shaped.master.contains(",mp4a.40.2\""), "\(shaped.master)")
    }
}
