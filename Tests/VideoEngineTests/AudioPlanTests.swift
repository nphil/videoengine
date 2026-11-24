import Foundation
import Testing
@testable import VideoEngine

struct AudioPlanTests {
    private func stream(_ index: Int, _ codec: String, channels: Int = 2, isDefault: Bool = false,
                        asc: [UInt8] = []) -> AudioStreamFacts {
        AudioStreamFacts(index: index, codec: codec, channels: channels, sampleRate: 48_000, bitsPerSample: 16,
                         isDefault: isDefault, audioSpecificConfig: asc)
    }

    @Test func picksThePreferredStreamThenTheDefaultThenTheFirst() {
        let streams = [stream(1, "ac3"), stream(2, "aac", isDefault: true, asc: [0x11, 0x90])]
        #expect(AudioPlan.decide(streams, policy: AudioPolicy())?.streamIndex == 2)
        #expect(AudioPlan.decide(streams, policy: AudioPolicy(preferredIndex: 1))?.streamIndex == 1)
        #expect(AudioPlan.decide([stream(3, "ac3"), stream(4, "ac3")], policy: AudioPolicy())?.streamIndex == 3)
        #expect(AudioPlan.decide([], policy: AudioPolicy()) == nil)
    }

    @Test func copiesProvenFormatsAndReencodesTheRest() {
        let policy = AudioPolicy()
        func action(_ facts: AudioStreamFacts) -> AudioPlan.Action? { AudioPlan.decide([facts], policy: policy)?.action }
        // AAC-LC stereo and HE-AAC with explicit SBR copy; a program config element (channels 0) does not.
        #expect(action(stream(0, "aac", asc: [0x11, 0x90])) == .copy)
        #expect(action(stream(0, "aac", asc: [0x29, 0x90])) == .copy)
        #expect(action(stream(0, "aac", asc: [0x11, 0x80])) == .reencode(channels: 2, bitRate: 192_000))
        #expect(action(stream(0, "eac3", channels: 6)) == .copy)
        #expect(action(stream(0, "eac3", channels: 8)) == .copyCore)
        #expect(action(stream(0, "truehd", channels: 8)) == .reencode(channels: 6, bitRate: 384_000))
        #expect(action(stream(0, "opus")) == .reencode(channels: 2, bitRate: 192_000))
        #expect(action(stream(0, "flac", channels: 6)) == .reencode(channels: 6, bitRate: 384_000))
        #expect(AudioPlan.decide([stream(0, "ac3")], policy: policy, forceReencode: true)?.copiedCodec == nil)
    }

    @Test func surroundThatCannotBeCopiedBecomesEAC3WhenAsked() throws {
        var policy = AudioPolicy()
        // Off by default: AAC, as before.
        #expect(policy.surroundCodec == .aac)
        policy.surroundCodec = .eac3
        func plan(_ facts: AudioStreamFacts, forceReencode: Bool = false) throws -> AudioPlan {
            try #require(AudioPlan.decide([facts], policy: policy, forceReencode: forceReencode))
        }
        for codec in ["truehd", "mlp", "dts", "opus"] {
            let surround = try plan(stream(0, codec, channels: 8))
            #expect(surround.action == .reencode(channels: 6, bitRate: 640_000, encoding: .eac3))
            #expect(surround.outputCodec == "eac3")
            #expect(surround.copiedCodec == nil)
            #expect(surround.retriesAsAAC)
        }
        // Stereo and mono stay AAC; copyable surround stays a copy.
        #expect(try plan(stream(0, "truehd")).action == .reencode(channels: 2, bitRate: 192_000))
        #expect(try plan(stream(0, "dts", channels: 1)).outputCodec == "aac")
        #expect(try plan(stream(0, "ac3", channels: 6)).action == .copy)
        #expect(try plan(stream(0, "eac3", channels: 8)).action == .copyCore)
        // The retry after a muxer failure is AAC, whatever the policy says.
        let retry = try plan(stream(0, "truehd", channels: 8), forceReencode: true)
        #expect(retry.action == .reencode(channels: 6, bitRate: 384_000))
        #expect(!retry.retriesAsAAC)
        // The bit rate is the policy's.
        policy.eac3BitRate = 448_000
        #expect(try plan(stream(0, "dts", channels: 6)).action == .reencode(channels: 6, bitRate: 448_000, encoding: .eac3))
    }

    @Test func shapingForcesAReencodeAndKeepsTheCodecChoice() throws {
        var policy = AudioPolicy()
        let aac = stream(0, "aac", asc: [0x11, 0x90])
        let ac3 = stream(1, "ac3", channels: 6)
        #expect(AudioPlan.decide([aac], policy: policy)?.shaping == nil)
        // Nothing set, or only values that clamp to nothing, shapes nothing.
        policy.shaping = AudioShaping(delay: 0.0004, dialogueLift: -3)
        #expect(AudioPlan.decide([aac], policy: policy)?.action == .copy)

        policy.shaping = AudioShaping(nightMode: true)
        let stereo = try #require(AudioPlan.decide([aac], policy: policy))
        #expect(stereo.action == .reencode(channels: 2, bitRate: 192_000))
        #expect(stereo.shaping == policy.shaping)
        #expect(stereo.copiedCodec == nil)
        #expect(!stereo.retriesAsAAC)
        let surround = try #require(AudioPlan.decide([ac3], policy: policy))
        #expect(surround.action == .reencode(channels: 6, bitRate: 384_000))

        policy.surroundCodec = .eac3
        #expect(AudioPlan.decide([ac3], policy: policy)?.action == .reencode(channels: 6, bitRate: 640_000, encoding: .eac3))
        // The fallback run keeps the shaping but not E-AC-3.
        let retry = try #require(AudioPlan.decide([ac3], policy: policy, forceReencode: true))
        #expect(retry.action == .reencode(channels: 6, bitRate: 384_000))
        #expect(retry.shaping == policy.shaping)
    }
}
