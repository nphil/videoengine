import Foundation
import LoopbackHLS
import Testing
@testable import VideoEngine

struct MuxPlanTests {
    private func plan(_ record: DolbyVisionConfiguration?, audio: [String] = ["aac"],
                      options: RemuxOptions = RemuxOptions()) -> MuxPlan {
        MuxPlan.decide(videoCodec: "hevc", dolbyVision: record, audioCodecs: audio, options: options)
    }

    @Test func profile5IsWrittenAsDvh1WithUnspecifiedColour() {
        let p5 = plan(DolbyVisionConfiguration(profile: 5, level: 6, compatibilityID: 0))
        #expect(p5.videoTag == "dvh1")
        #expect(p5.dolbyVision == .keep)
        #expect(p5.unspecifiedColour)
        #expect(p5.movflags.contains("write_colr"))
        #expect(p5.muxerOptions["strict"] == "unofficial")
    }

    @Test func profile7IsCutToItsBaseLayerAndProfile8KeepsDolbyVision() {
        let p7 = plan(DolbyVisionConfiguration(profile: 7, level: 6, compatibilityID: 6, hasEnhancementLayer: true))
        #expect(p7.dolbyVision == .strip)
        #expect(p7.videoTag == "hvc1")

        let p81 = DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 1)
        #expect(plan(p81).dolbyVision == .keep)
        #expect(plan(p81).videoTag == "hvc1")
        var baseOnly = RemuxOptions()
        baseOnly.dolbyVision = .baseLayerOnly
        #expect(plan(p81, options: baseOnly).dolbyVision == .drop)
        // An SDR base layer (8.2) is not worth a Dolby Vision label.
        #expect(plan(DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 2)).dolbyVision == .drop)
    }

    @Test func serverRecordIsAddedOnlyWhenTheFileHasNone() {
        let server = DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 1)
        var options = RemuxOptions()
        options.dolbyVisionFallback = server
        #expect(plan(nil, options: options).dolbyVision == .add(server))
        #expect(plan(DolbyVisionConfiguration(profile: 8, level: 9, compatibilityID: 4), options: options).dolbyVision == .keep)
        #expect(plan(nil).dolbyVision == .none)
    }

    @Test func dolbyDigitalAudioDelaysTheInitSegment() {
        let ac3 = plan(nil, audio: ["eac3"])
        #expect(ac3.movflags.contains("delay_moov"))
        #expect(ac3.muxerOptions["use_editlist"] == "0")
        #expect(!plan(nil).movflags.contains("delay_moov"))
    }

    @Test func profile7BecomesSingleLayerProfile81OnlyWhenAsked() {
        let p7 = DolbyVisionConfiguration(profile: 7, level: 6, compatibilityID: 6, hasEnhancementLayer: true)
        var options = RemuxOptions()
        options.dolbyVision = .profile7AsProfile8
        let converted = plan(p7, options: options)
        #expect(converted.dolbyVision == .convertToProfile81(
            DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 1, hasRPU: true, hasEnhancementLayer: false)
        ))
        #expect(converted.videoTag == "hvc1")
        #expect(converted.muxerOptions["strict"] == "unofficial")
        // Without the option, and by default, profile 7 is still cut to its base layer.
        #expect(plan(p7).dolbyVision == .strip)
        // A record with no RPU has nothing to convert; other profiles are as in automatic.
        let noRPU = DolbyVisionConfiguration(profile: 7, level: 6, compatibilityID: 6, hasRPU: false, hasEnhancementLayer: true)
        #expect(plan(noRPU, options: options).dolbyVision == .strip)
        let p81 = DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 1)
        #expect(plan(p81, options: options).dolbyVision == .keep)
        // A source with no record takes the fallback as before, and a profile 7 fallback converts too.
        options.dolbyVisionFallback = p7
        #expect(plan(nil, options: options).dolbyVision == .convertToProfile81(
            DolbyVisionConfiguration(profile: 8, level: 6, compatibilityID: 1, hasRPU: true, hasEnhancementLayer: false)
        ))
    }
}
