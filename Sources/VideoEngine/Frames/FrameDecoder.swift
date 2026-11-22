import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import VideoToolbox

/// Decodes one keyframe at a time: with VideoToolbox when the device and the codec allow it, and with FFmpeg's own
/// decoder otherwise (libdav1d for AV1). Used only from the worker queue.
final class FrameDecoder {
    enum Path: String {
        case videoToolbox
        case software
    }

    private(set) var path: Path
    private var codec: FFCodecContext
    private let stream: UnsafeMutablePointer<AVStream>

    init(stream: UnsafeMutablePointer<AVStream>) throws {
        let opened = try Self.makeContext(stream: stream)
        self.stream = stream
        codec = opened.context
        path = opened.path
    }

    /// Reopens the decoder in software, for good: VideoToolbox could not decode this video.
    func switchToSoftware() throws {
        codec = try Self.openSoftware(stream: stream)
        path = .software
    }

    /// Decodes the keyframe in `packet` and leaves the picture it produces in `frame`. The packet stays the
    /// caller's, so a failed attempt can be repeated with another decoder.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>, into frame: UnsafeMutablePointer<AVFrame>) throws {
        av_frame_unref(frame)
        // Starts from nothing: the previous call left the decoder at the end of its stream.
        avcodec_flush_buffers(codec.pointer)
        let sent = avcodec_send_packet(codec.pointer, packet)
        guard sent >= 0 else { throw VideoEngineError.failure("decode", sent) }
        // End of stream straight after the keyframe, so the decoder hands the picture over without waiting for
        // more packets. Whatever else it holds is dropped by the next flush.
        _ = avcodec_send_packet(codec.pointer, nil)
        let received = avcodec_receive_frame(codec.pointer, frame)
        if received == FF.eagain || received == FF.averrorEOF { throw VideoEngineError.noFrame }
        guard received >= 0 else { throw VideoEngineError.failure("decode", received) }
    }

    private static func makeContext(stream: UnsafeMutablePointer<AVStream>) throws -> (context: FFCodecContext, path: Path) {
        if let hardware = openVideoToolbox(stream: stream) { return (hardware, .videoToolbox) }
        let software = try openSoftware(stream: stream)
        return (software, .software)
    }

    /// A VideoToolbox decoder, or nil when this device, codec or build cannot offer one; the caller falls back to
    /// software.
    private static func openVideoToolbox(stream: UnsafeMutablePointer<AVStream>) -> FFCodecContext? {
        #if targetEnvironment(simulator)
        // The Simulator's VideoToolbox is not representative, so pictures there come from FFmpeg alone.
        return nil
        #else
        guard let parameters = stream.pointee.codecpar else { return nil }
        let name = codecName(of: parameters)
        guard let type = VideoStreamFacts.codecType(ffmpegName: name), VTIsHardwareDecodeSupported(type) else {
            return nil
        }
        // AV1 reaches VideoToolbox through FFmpeg's own hardware-only decoder; libdav1d would ignore the device.
        let found = name == "av1"
            ? avcodec_find_decoder_by_name("av1") : avcodec_find_decoder(parameters.pointee.codec_id)
        guard let codec = found, let context = try? FFCodecContext(codec: codec),
              configure(context, stream: stream, parameters: parameters) else { return nil }
        // The device and get_format must be in place before the decoder opens; without them it decodes on the
        // CPU. The decoder owns the device reference from here on.
        var device: UnsafeMutablePointer<AVBufferRef>?
        guard av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0,
              let hardware = device else { return nil }
        context.pointer.pointee.hw_device_ctx = hardware
        context.pointer.pointee.get_format = preferVideoToolbox
        context.pointer.pointee.thread_count = 1
        guard avcodec_open2(context.pointer, codec, nil) >= 0 else { return nil }
        return context
        #endif
    }

    private static func openSoftware(stream: UnsafeMutablePointer<AVStream>) throws -> FFCodecContext {
        guard let parameters = stream.pointee.codecpar else { throw VideoEngineError.noPlayableStreams }
        let name = codecName(of: parameters)
        // FFmpeg's own AV1 decoder only drives hardware, so AV1 in software means libdav1d.
        let found = name == "av1"
            ? avcodec_find_decoder_by_name("libdav1d") : avcodec_find_decoder(parameters.pointee.codec_id)
        guard let codec = found else { throw VideoEngineError.decoderUnavailable(codec: name) }
        let context = try FFCodecContext(codec: codec)
        guard configure(context, stream: stream, parameters: parameters) else {
            throw VideoEngineError.decoderUnavailable(codec: name)
        }
        // One picture is all it decodes: slices can share the work, frames have nothing to overlap.
        context.pointer.pointee.thread_count = Int32(min(ProcessInfo.processInfo.activeProcessorCount, 4))
        context.pointer.pointee.thread_type = FF.threadSlice
        guard avcodec_open2(context.pointer, codec, nil) >= 0 else {
            throw VideoEngineError.decoderUnavailable(codec: name)
        }
        return context
    }

    /// The settings both decoders share: the stream's parameters, its time base for timestamps, and low delay,
    /// which keeps libdav1d from queueing frames and turns frame threading off.
    private static func configure(
        _ context: FFCodecContext, stream: UnsafeMutablePointer<AVStream>,
        parameters: UnsafeMutablePointer<AVCodecParameters>
    ) -> Bool {
        guard avcodec_parameters_to_context(context.pointer, parameters) >= 0 else { return false }
        context.pointer.pointee.pkt_timebase = stream.pointee.time_base
        context.pointer.pointee.flags |= FF.codecFlagLowDelay
        return true
    }

    private static func codecName(of parameters: UnsafeMutablePointer<AVCodecParameters>) -> String {
        FF.string(avcodec_get_name(parameters.pointee.codec_id)) ?? "unknown"
    }
}
