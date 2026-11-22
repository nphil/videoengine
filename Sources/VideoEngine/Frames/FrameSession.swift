import CoreGraphics
import Foundation
import Libavcodec
import Libavformat
import Libavutil

extension VideoEngineError {
    /// The video has no picture at or before the requested time that can be shown: none is stored that early, none
    /// decodes, or the one that does has no timestamp to report.
    static let noFrame = VideoEngineError.ffmpeg(
        code: FF.invalidData, message: "no picture at or before that time could be decoded"
    )
}

/// An open video kept between calls: its demuxer, decoder and scaler. Used only from the worker queue.
final class FrameSession {
    /// How far a picture may sit past the requested time and still count as at it: floating-point rounding only.
    private static let rounding = 1e-6

    /// The demuxer's input. The worker clears the error an interrupted call left on it before the next call.
    let input: DemuxInput
    private let streamIndex: Int
    private let stream: UnsafeMutablePointer<AVStream>
    /// Seconds the container's timeline starts above zero (an MPEG-TS stream starts a second or so in), so that
    /// frame times are movie times, as in playback.
    private let startOffset: Double
    private let decoder: FrameDecoder
    private let renderer: FrameRenderer
    private let packet: FFPacket
    private let decoded: FFFrame
    private let logger: EngineLogger
    private var loggedPath = false

    /// Opens `source`, reads enough of it to know its streams, and sets up the decoder for the video stream playback
    /// would pick. Throws what the source throws, `CancellationError` when the run is stopped, or why the video
    /// cannot give pictures.
    init(source: any ByteRangeSource, control: RunControl, logger: EngineLogger) throws {
        let started = DispatchTime.now()
        let input = try DemuxInput(source: source, control: control, bufferSize: 64 << 10)
        let found = avformat_find_stream_info(input.context, nil)
        guard found >= 0 else { throw input.failure(code: found) }
        let index = Remuxer.videoStream(of: input.context)
        guard index >= 0, let stream = input.stream(index), let parameters = stream.pointee.codecpar else {
            throw VideoEngineError.noPlayableStreams
        }
        guard Int(parameters.pointee.width) * Int(parameters.pointee.height) <= FrameLimits.sourcePixels else {
            throw VideoEngineError.unsupportedSource("the pictures are larger than 8K")
        }
        let decoder = try FrameDecoder(stream: stream)
        let start = input.context.pointee.start_time
        self.input = input
        streamIndex = index
        self.stream = stream
        startOffset = start == FF.noPTS ? 0 : Double(start) / Double(FF.timeBase)
        self.decoder = decoder
        renderer = FrameRenderer(stream: stream)
        packet = try FFPacket()
        decoded = try FFFrame()
        self.logger = logger
        logger.event("frames-open", [
            ("source", source.logName),
            ("codec", FF.string(avcodec_get_name(parameters.pointee.codec_id)) ?? "unknown"),
            ("size", "\(parameters.pointee.width)x\(parameters.pointee.height)"),
            ("decoder", decoder.path.rawValue),
            ("ms", String(milliseconds(since: started))),
        ])
    }

    /// The picture at the keyframe at or before `seconds`, and the movie time it is shown at, never later than
    /// `seconds`. Throws `noFrame` when the video has no keyframe that early or gives the picture no timestamp, and
    /// `CancellationError` as soon as `job` is cancelled.
    func frame(at seconds: Double, maxWidth: Int, job: FrameJob) throws -> (image: CGImage, seconds: Double) {
        try job.checkCancelled()
        try seek(to: seconds)
        defer { av_packet_unref(packet.pointer) }
        try readKeyframe(job: job)
        let picture = try decodePicture(maxWidth: maxWidth, job: job)
        let shown = try shownSeconds(stamp: picture.stamp, notAfter: seconds)
        return (picture.image, shown)
    }

    /// Decodes and renders the keyframe in `packet`. VideoToolbox goes first; when it declines the video or the
    /// picture, the rest is software, for good.
    private func decodePicture(maxWidth: Int, job: FrameJob) throws -> (image: CGImage, stamp: Int64) {
        do {
            return try decodeAndRender(maxWidth: maxWidth, job: job)
        } catch {
            guard decoder.path == .videoToolbox, !job.isCancelled, !(error is CancellationError) else { throw error }
            logger.event("frames-fallback", [("error", String(describing: error))])
            try decoder.switchToSoftware()
            loggedPath = false
            return try decodeAndRender(maxWidth: maxWidth, job: job)
        }
    }

    /// Points the demuxer at the keyframe at or before `seconds`, the way playback seeks.
    private func seek(to seconds: Double) throws {
        let base = stream.pointee.time_base
        guard base.num > 0, base.den > 0 else { throw VideoEngineError.failure("seek", FF.einval) }
        // A damaged or hostile start time could push the target past 64 bits, which would trap.
        let ticks = ((seconds + startOffset) * Double(base.den) / Double(base.num)).rounded(.down)
        guard ticks.magnitude < 9e18 else { throw VideoEngineError.failure("seek", FF.einval) }
        let target = Int64(ticks)
        let sought = av_seek_frame(input.context, Int32(streamIndex), target, FF.seekBackward)
        guard sought >= 0 else {
            // A failed read can look like a failed seek: the source's own error says more.
            if let error = input.readError { throw error }
            if sought == FF.averrorExit { throw input.failure(code: sought) }
            throw VideoEngineError.failure("seek", sought)
        }
    }

    /// Reads packets until the first video keyframe, which is left in `packet`.
    private func readKeyframe(job: FrameJob) throws {
        var searched = 0
        while true {
            try job.checkCancelled()
            av_packet_unref(packet.pointer)
            guard try input.nextPacket(into: packet.pointer) else { throw VideoEngineError.noFrame }
            let size = Int(packet.pointer.pointee.size)
            if packet.pointer.pointee.stream_index == Int32(streamIndex),
               packet.pointer.pointee.flags & FF.packetFlagKey != 0, size > 0 {
                return
            }
            searched += size
            if searched > FrameLimits.keyframeSearchBytes { throw VideoEngineError.noFrame }
        }
    }

    /// The decoded keyframe as a picture, with the timestamp the video gave it.
    private func decodeAndRender(maxWidth: Int, job: FrameJob) throws -> (image: CGImage, stamp: Int64) {
        try decoder.decode(packet.pointer, into: decoded.pointer)
        defer { av_frame_unref(decoded.pointer) }
        try job.checkCancelled()
        if !loggedPath {
            loggedPath = true
            let hardware = decoded.pointer.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
            logger.event("frames-decode", [("path", hardware ? "videotoolbox" : "software")])
        }
        let image = try renderer.image(from: decoded.pointer, maxWidth: maxWidth)
        return (image, timestamp(of: decoded.pointer))
    }

    /// The first timestamp the decoder or the demuxer gave the picture, in the stream's time base; `FF.noPTS` when it
    /// has none.
    private func timestamp(of frame: UnsafeMutablePointer<AVFrame>) -> Int64 {
        let stamps = [
            frame.pointee.best_effort_timestamp, frame.pointee.pts, packet.pointer.pointee.pts,
            packet.pointer.pointee.dts,
        ]
        return stamps.first { $0 != FF.noPTS } ?? FF.noPTS
    }

    /// The movie time of a timestamp, never a guess: a picture with no timestamp is an error, and so is one shown
    /// after `limit`, which means the video has no keyframe that early. The seek aims at a whole tick at or below the
    /// request, so only floating-point rounding is let through, and the result is held to `limit`.
    private func shownSeconds(stamp: Int64, notAfter limit: Double) throws -> Double {
        guard stamp != FF.noPTS else { throw VideoEngineError.noFrame }
        let shown = max(0, Double(stamp) * av_q2d(stream.pointee.time_base) - startOffset)
        guard shown <= limit + Self.rounding else { throw VideoEngineError.noFrame }
        return min(shown, limit)
    }
}
