import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Testing
@testable import VideoEngine

/// Audio made up in the test, so nothing depends on a media file.
enum SyntheticAudio {
    static let rate = 48_000

    static func check(_ code: Int32, _ step: String) throws {
        guard code >= 0 else { throw VideoEngineError.failure(step, code) }
    }

    /// A tone at `frequency` and `amplitude`, `seconds` long.
    static func sine(_ frequency: Double, amplitude: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / Double(rate))) }
    }

    /// Runs planar float `channels` through the shaping graph for `chain`, 1024 samples at a time, and
    /// returns what comes out, as planar float too.
    static func shape(_ channels: [[Float]], layout: String, chain: String) throws -> [[Float]] {
        let total = channels[0].count
        let owner = try FFFrame()
        defer { withExtendedLifetime(owner) {} }
        var shaper: AudioShaper?
        var shaped = [[Float]](repeating: [], count: channels.count)
        func collect(_ frame: UnsafeMutablePointer<AVFrame>) {
            let samples = Int(frame.pointee.nb_samples)
            for channel in channels.indices {
                let plane = UnsafeRawPointer(frame.pointee.extended_data[channel]!).assumingMemoryBound(to: Float.self)
                shaped[channel].append(contentsOf: UnsafeBufferPointer(start: plane, count: samples))
            }
        }
        var start = 0
        while start < total {
            let size = min(1024, total - start)
            let frame = owner.pointer
            av_frame_unref(frame)
            frame.pointee.nb_samples = Int32(size)
            frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            frame.pointee.sample_rate = Int32(rate)
            try check(av_channel_layout_from_string(&frame.pointee.ch_layout, layout), "layout")
            try check(av_frame_get_buffer(frame, 0), "frame buffer")
            for channel in channels.indices {
                let plane = UnsafeMutableRawPointer(frame.pointee.extended_data[channel]!).assumingMemoryBound(to: Float.self)
                for i in 0..<size { plane[i] = channels[channel][start + i] }
            }
            // The graph's own output format varies by filter; planar float is what the test reads.
            if shaper == nil { shaper = try AudioShaper(chain: chain + ",aformat=sample_fmts=fltp", matching: frame) }
            try shaper?.push(frame, deliver: collect)
            start += size
        }
        try shaper?.push(nil, deliver: collect)
        return shaped
    }

    /// An input context with one 16-bit PCM stream, which is all `AudioReencoder` needs of a source.
    final class PCMSource {
        let format: UnsafeMutablePointer<AVFormatContext>
        let stream: UnsafeMutablePointer<AVStream>
        let channels: Int

        init(channels: Int) throws {
            guard let format = avformat_alloc_context(), let stream = avformat_new_stream(format, nil) else {
                throw VideoEngineError.outOfMemory
            }
            self.format = format
            self.stream = stream
            self.channels = channels
            let parameters = stream.pointee.codecpar!
            parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
            parameters.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
            parameters.pointee.format = AV_SAMPLE_FMT_S16.rawValue
            parameters.pointee.sample_rate = Int32(rate)
            av_channel_layout_default(&parameters.pointee.ch_layout, Int32(channels))
            parameters.pointee.bits_per_coded_sample = 16
            parameters.pointee.block_align = Int32(2 * channels)
            parameters.pointee.bit_rate = Int64(16 * channels * rate)
            stream.pointee.time_base = AVRational(num: 1, den: Int32(rate))
        }

        deinit { avformat_free_context(format) }

        /// Feeds `samples` samples starting at `first` to `reencoder`, keeping the packet alive while it reads it.
        func feed(_ reencoder: AudioReencoder, first: Int, samples: Int) throws -> [FFPacket] {
            let chunk = try packet(first: first, samples: samples)
            return try withExtendedLifetime(chunk) { try reencoder.process(chunk.pointer) }
        }

        /// `samples` samples of a tone per channel starting at sample `first`, as a packet in the stream's time base.
        func packet(first: Int, samples: Int) throws -> FFPacket {
            let owner = try FFPacket()
            try check(av_new_packet(owner.pointer, Int32(samples * 2 * channels)), "packet")
            let values = UnsafeMutableRawPointer(owner.pointer.pointee.data!).assumingMemoryBound(to: Int16.self)
            for i in 0..<samples {
                for channel in 0..<channels {
                    let phase = 2 * Double.pi * Double(220 * (channel + 1)) * Double(first + i) / Double(rate)
                    values[i * channels + channel] = Int16(6000 * sin(phase))
                }
            }
            owner.pointer.pointee.pts = Int64(first)
            owner.pointer.pointee.dts = Int64(first)
            owner.pointer.pointee.duration = Int64(samples)
            owner.pointer.pointee.stream_index = 0
            return owner
        }
    }

    /// An output context with a bare stream for `AudioReencoder` to describe its encoded audio on.
    final class Sink {
        let format: UnsafeMutablePointer<AVFormatContext>
        let stream: UnsafeMutablePointer<AVStream>

        init() throws {
            guard let format = avformat_alloc_context(), let stream = avformat_new_stream(format, nil) else {
                throw VideoEngineError.outOfMemory
            }
            self.format = format
            self.stream = stream
        }

        deinit { avformat_free_context(format) }
    }

    /// The first audio stream's channel count, layout order and sample format as read back from `url`, for failure text.
    static func describeAudio(of url: URL) -> String {
        var input: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&input, url.path, nil, nil) >= 0, let source = input else { return "cannot open" }
        defer { avformat_close_input(&input) }
        _ = avformat_find_stream_info(source, nil)
        for i in 0..<Int(source.pointee.nb_streams) {
            let parameters = source.pointee.streams[i]!.pointee.codecpar!
            if parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                return "audio channels=\(parameters.pointee.ch_layout.nb_channels) order=\(parameters.pointee.ch_layout.order.rawValue) "
                    + "format=\(parameters.pointee.format) rate=\(parameters.pointee.sample_rate)"
            }
        }
        return "no audio"
    }

    /// A Matroska file with the video of `h264-aac.mkv` and `seconds` of 16-bit PCM 5.1 in place of its audio.
    static func writeSurroundMatroska(to url: URL, seconds: Int) throws {
        var input: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&input, try Fixture.url("h264-aac.mkv").path, nil, nil), "open fixture")
        defer { avformat_close_input(&input) }
        guard let source = input else { throw VideoEngineError.outOfMemory }
        try check(avformat_find_stream_info(source, nil), "probe fixture")
        guard let videoIndex = (0..<Int(source.pointee.nb_streams)).first(where: {
            source.pointee.streams[$0]!.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO
        }) else { throw VideoEngineError.noPlayableStreams }
        let sourceVideo = source.pointee.streams[videoIndex]!

        var created: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&created, nil, "matroska", url.path), "create output")
        guard let output = created else { throw VideoEngineError.outOfMemory }
        defer {
            if output.pointee.pb != nil { avio_closep(&output.pointee.pb) }
            avformat_free_context(output)
        }
        guard let video = avformat_new_stream(output, nil), let audio = avformat_new_stream(output, nil) else {
            throw VideoEngineError.outOfMemory
        }
        try check(avcodec_parameters_copy(video.pointee.codecpar, sourceVideo.pointee.codecpar), "copy video parameters")
        video.pointee.codecpar.pointee.codec_tag = 0
        let parameters = audio.pointee.codecpar!
        parameters.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        parameters.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        parameters.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        parameters.pointee.sample_rate = Int32(rate)
        av_channel_layout_default(&parameters.pointee.ch_layout, 6)
        parameters.pointee.bits_per_coded_sample = 16
        parameters.pointee.block_align = 12
        parameters.pointee.bit_rate = Int64(16 * 6 * rate)
        audio.pointee.time_base = AVRational(num: 1, den: Int32(rate))
        try check(avio_open(&output.pointee.pb, url.path, FF.avioFlagWrite), "open output file")
        try check(avformat_write_header(output, nil), "write header")

        let packet = try FFPacket()
        defer { withExtendedLifetime(packet) {} }
        while av_read_frame(source, packet.pointer) >= 0 {
            defer { av_packet_unref(packet.pointer) }
            guard Int(packet.pointer.pointee.stream_index) == videoIndex else { continue }
            packet.pointer.pointee.stream_index = video.pointee.index
            av_packet_rescale_ts(packet.pointer, sourceVideo.pointee.time_base, video.pointee.time_base)
            try check(av_interleaved_write_frame(output, packet.pointer), "write video")
        }
        let tone = try PCMSource(channels: 6)
        var first = 0
        while first < seconds * rate {
            let chunk = try tone.packet(first: first, samples: 1024)
            defer { withExtendedLifetime(chunk) {} }
            let base = AVRational(num: 1, den: Int32(rate))
            chunk.pointer.pointee.pts = av_rescale_q(Int64(first), base, audio.pointee.time_base)
            chunk.pointer.pointee.dts = chunk.pointer.pointee.pts
            chunk.pointer.pointee.duration = av_rescale_q(1024, base, audio.pointee.time_base)
            chunk.pointer.pointee.stream_index = audio.pointee.index
            try check(av_interleaved_write_frame(output, chunk.pointer), "write audio")
            first += 1024
        }
        try check(av_write_trailer(output), "write trailer")
    }
}

struct AudioShapingTests {
    private static let rate = SyntheticAudio.rate

    private func index(ofPeakIn samples: [Float]) -> Int? {
        samples.indices.max { abs(samples[$0]) < abs(samples[$1]) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
    }

    @Test func buildsOnlyWhatIsAskedFor() {
        #expect(AudioShaping().filterChain(channels: 2, sampleRate: Self.rate) == nil)
        #expect(!AudioShaping().isActive)
        // Clamped to two seconds and a whole millisecond.
        #expect(AudioShaping(delay: 9).delayMilliseconds == 2000)
        #expect(AudioShaping(delay: -9).delayMilliseconds == -2000)
        #expect(AudioShaping(delay: 0.0126).delayMilliseconds == 13)
        #expect(AudioShaping(delay: .nan).delayMilliseconds == 0)
        #expect(AudioShaping(dialogueLift: 40).liftDecibels == AudioShaping.maxDialogueLift)
        #expect(AudioShaping(dialogueLift: -4).liftDecibels == 0)
        #expect(AudioShaping(delay: 0.25).filterChain(channels: 6, sampleRate: Self.rate) == "adelay=delays=250:all=1")
        #expect(AudioShaping(delay: -0.25).filterChain(channels: 6, sampleRate: Self.rate) == "atrim=start_sample=12000")
        let night = AudioShaping(nightMode: true).filterChain(channels: 2, sampleRate: Self.rate)
        #expect(night?.hasPrefix("acompressor=") == true)
        #expect(night?.contains(",alimiter=") == true)
        let lifted = AudioShaping(delay: 0.1, dialogueLift: 6, nightMode: true).filterChain(channels: 6, sampleRate: Self.rate)
        let order = ["pan=5.1(side)", "acompressor=", "adelay="].compactMap { lifted?.range(of: $0)?.lowerBound }
        #expect(order.count == 3 && order == order.sorted())
    }

    @Test func delayMovesTheSoundLaterAndEarlier() throws {
        var impulse = [Float](repeating: 0, count: 4096)
        impulse[1000] = 0.5
        let silence = [Float](repeating: 0, count: 4096)
        let later = try SyntheticAudio.shape(
            [impulse, silence], layout: "stereo", chain: try #require(AudioShaping(delay: 0.01).filterChain(channels: 2, sampleRate: Self.rate))
        )
        // 10 ms is 480 samples; the tail grows by as much.
        #expect(index(ofPeakIn: later[0]) == 1480)
        #expect(later[0].count == 4096 + 480)
        let earlier = try SyntheticAudio.shape(
            [impulse, silence], layout: "stereo", chain: try #require(AudioShaping(delay: -0.01).filterChain(channels: 2, sampleRate: Self.rate))
        )
        #expect(index(ofPeakIn: earlier[0]) == 520)
        #expect(earlier[0].count == 4096 - 480)
        #expect(abs(earlier[0][520] - 0.5) < 1e-4)
    }

    @Test func dialogueLiftRaisesTheCentreOfSurroundOnly() throws {
        let level: Float = 0.1
        let channels = [[Float]](repeating: [Float](repeating: level, count: 4096), count: 6)
        let chain = try #require(AudioShaping(dialogueLift: 6).filterChain(channels: 6, sampleRate: Self.rate))
        let shaped = try SyntheticAudio.shape(channels, layout: "5.1(side)", chain: chain)
        let gain = Float(pow(10, 6.0 / 20))
        for (channel, samples) in shaped.enumerated() {
            #expect(samples.count == 4096)
            // 5.1(side) order is FL, FR, FC, LFE, SL, SR.
            let expected = channel == 2 ? level * gain : level
            #expect(abs(samples[2000] - expected) < 1e-3, "channel \(channel): \(samples[2000]) is not \(expected)")
        }
    }

    @Test func dialogueLiftRaisesTheMidOfStereoAndLeavesTheSides() throws {
        let chain = try #require(AudioShaping(dialogueLift: 6).filterChain(channels: 2, sampleRate: Self.rate))
        let gain = Float(pow(10, 6.0 / 20))
        let flat = [Float](repeating: 0.1, count: 4096)
        // The same in both ears is all mid: it gains the full amount.
        let mid = try SyntheticAudio.shape([flat, flat], layout: "stereo", chain: chain)
        #expect(abs(mid[0][2000] - 0.1 * gain) < 1e-3 && abs(mid[1][2000] - 0.1 * gain) < 1e-3)
        // Opposite in the two ears is all side: unchanged.
        let side = try SyntheticAudio.shape([flat, flat.map { -$0 }], layout: "stereo", chain: chain)
        #expect(abs(side[0][2000] - 0.1) < 1e-3 && abs(side[1][2000] + 0.1) < 1e-3)
    }

    @Test func nightModeNarrowsTheGapBetweenLoudAndQuiet() throws {
        let chain = try #require(AudioShaping(nightMode: true).filterChain(channels: 2, sampleRate: Self.rate))
        func steadyLevel(_ amplitude: Float) throws -> (input: Double, output: Double, peak: Float) {
            let tone = SyntheticAudio.sine(1000, amplitude: amplitude, seconds: 2)
            let shaped = try SyntheticAudio.shape([tone, tone], layout: "stereo", chain: chain)
            // The last half second, once the compressor has settled.
            let tail = shaped[0].count - Self.rate / 2..<shaped[0].count
            return (rms(tone[tone.count - Self.rate / 2..<tone.count]), rms(shaped[0][tail]), shaped[0].map { abs($0) }.max() ?? 0)
        }
        let loud = try steadyLevel(0.9)
        let quiet = try steadyLevel(0.03)
        // 30 in, well under that out; quiet passages are not made quieter, loud ones are, and the limit holds.
        #expect(loud.input / quiet.input > 25)
        #expect(loud.output / quiet.output < 10)
        #expect(quiet.output > quiet.input)
        #expect(loud.output < loud.input)
        #expect(loud.peak <= 0.91)
    }

    @Test func theReencoderEncodesSurroundAsEAC3() throws {
        let source = try SyntheticAudio.PCMSource(channels: 6)
        let sink = try SyntheticAudio.Sink()
        let reencoder = try AudioReencoder(
            stream: source.stream, output: sink.stream, channels: 6, bitRate: 640_000, encoding: .eac3
        )
        let parameters = sink.stream.pointee.codecpar!
        #expect(parameters.pointee.codec_id == AV_CODEC_ID_EAC3)
        #expect(parameters.pointee.ch_layout.nb_channels == 6)
        #expect(parameters.pointee.bit_rate == 640_000)
        var packets: [FFPacket] = []
        for first in stride(from: 0, to: 2 * Self.rate, by: 1536) {
            packets += try source.feed(reencoder, first: first, samples: 1536)
        }
        packets += try reencoder.process(nil)
        #expect(packets.count >= 62)
        // Constant bit rate: 640 kbit/s is 2560 bytes for each 1536 samples at 48 kHz.
        #expect(Set(packets.map { Int($0.pointer.pointee.size) }) == [2560])
    }

    @Test func theReencoderAppliesShapingToTheEncodedAudio() throws {
        func packetCount(_ shaping: AudioShaping?) throws -> Int {
            let source = try SyntheticAudio.PCMSource(channels: 6)
            let sink = try SyntheticAudio.Sink()
            let reencoder = try AudioReencoder(
                stream: source.stream, output: sink.stream, channels: 6, bitRate: 640_000, encoding: .eac3, shaping: shaping
            )
            var count = 0
            for first in stride(from: 0, to: 2 * Self.rate, by: 1536) {
                count += try source.feed(reencoder, first: first, samples: 1536).count
            }
            return count + (try reencoder.process(nil)).count
        }
        let plain = try packetCount(nil)
        // Half a second more sound is 24000 samples, about 16 frames of 1536.
        let delayed = try packetCount(AudioShaping(delay: 0.5))
        #expect((plain + 15)...(plain + 17) ~= delayed, "\(plain) frames, \(delayed) delayed")
        // Every filter in one chain, through the same path.
        let everything = try packetCount(AudioShaping(delay: 0.5, dialogueLift: 6, nightMode: true))
        #expect((plain + 14)...(plain + 18) ~= everything, "\(plain) frames, \(everything) shaped")
    }
}
