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

    /// What a run that did not finish saw, as the text of the error that fails the test.
    private struct Unfinished: Error, CustomStringConvertible {
        var description: String
    }

    private func remux(_ fixture: URL, audio: AudioPolicy) async throws -> Outcome {
        var options = RemuxOptions()
        options.audio = audio
        let plans = OSAllocatedUnfairLock(initialState: [String]())
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let logger = EngineLogger(
            event: { tag, fields in
                lines.withLock { $0.append("\(tag) \(fields.map { "\($0.0)=\($0.1)" }.joined(separator: " "))") }
                guard tag == "remux-plan", let plan = fields.first(where: { $0.0 == "audio" })?.1 else { return }
                plans.withLock { $0.append(plan) }
            },
            message: { text in lines.withLock { $0.append(text) } }
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
        var ending = "no end event"
        events: for await event in session.events {
            switch event {
            case .finished:
                ending = "finished"
                break events
            case .failed(let error, _):
                ending = "failed: \(error)"
                break events
            case .stopped:
                ending = "stopped"
                break events
            default:
                continue
            }
        }
        guard ending == "finished" else {
            throw Unfinished(description: "\(ending)\n" + lines.withLock { $0 }.suffix(40).joined(separator: "\n"))
        }
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
