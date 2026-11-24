import Foundation
import Libavfilter
import Libavutil

/// A libavfilter graph over decoded audio frames, built from the first frame's format. Frames go in as
/// the decoder produces them and come out shaped, in whatever format the last filter writes. The output
/// carries no useful timestamps: the graph counts samples, so the caller does too. Confined to the remux
/// thread.
final class AudioShaper {
    private let graph: UnsafeMutablePointer<AVFilterGraph>
    private let source: UnsafeMutablePointer<AVFilterContext>
    private let sink: UnsafeMutablePointer<AVFilterContext>
    private let shaped: FFFrame
    /// Samples fed so far, which is the next frame's timestamp in a time base of 1 / sample rate.
    private var fed: Int64 = 0

    /// Builds the graph for frames laid out like `frame` and filtered by `chain`.
    init(chain: String, matching frame: UnsafeMutablePointer<AVFrame>) throws {
        shaped = try FFFrame()
        let configured = try Self.configure(chain: chain, matching: frame)
        graph = configured.0
        source = configured.1
        sink = configured.2
    }

    deinit {
        var freed: UnsafeMutablePointer<AVFilterGraph>? = graph
        avfilter_graph_free(&freed)
    }

    /// The configured graph with its input and output; a graph that cannot be configured is freed.
    private static func configure(chain: String, matching frame: UnsafeMutablePointer<AVFrame>) throws -> (
        UnsafeMutablePointer<AVFilterGraph>, UnsafeMutablePointer<AVFilterContext>, UnsafeMutablePointer<AVFilterContext>
    ) {
        let rate = frame.pointee.sample_rate
        var layout = frame.pointee.ch_layout
        let capacity = 128
        var layoutName = [CChar](repeating: 0, count: capacity)
        var result = av_channel_layout_describe(&layout, &layoutName, capacity)
        guard result >= 0 else { throw VideoEngineError.failure("describe audio layout", result) }
        guard let formatName = av_get_sample_fmt_name(AVSampleFormat(rawValue: frame.pointee.format)),
              let sourceFilter = avfilter_get_by_name("abuffer"), let sinkFilter = avfilter_get_by_name("abuffersink"),
              let graph = avfilter_graph_alloc() else { throw VideoEngineError.outOfMemory }
        var built: UnsafeMutablePointer<AVFilterGraph>? = graph
        var succeeded = false
        defer { if !succeeded { avfilter_graph_free(&built) } }

        var sourceContext: UnsafeMutablePointer<AVFilterContext>?
        let arguments = "time_base=1/\(rate):sample_rate=\(rate):sample_fmt=\(String(cString: formatName))"
            + ":channel_layout=\(String(cString: layoutName))"
        result = avfilter_graph_create_filter(&sourceContext, sourceFilter, "in", arguments, nil, graph)
        guard result >= 0, let sourceContext else { throw VideoEngineError.failure("open audio filter input", result) }
        var sinkContext: UnsafeMutablePointer<AVFilterContext>?
        result = avfilter_graph_create_filter(&sinkContext, sinkFilter, "out", nil, nil, graph)
        guard result >= 0, let sinkContext else { throw VideoEngineError.failure("open audio filter output", result) }

        // The graph's open ends: what feeds the chain is named "in" and what the chain feeds is "out".
        var openInputs = avfilter_inout_alloc()
        var openOutputs = avfilter_inout_alloc()
        defer {
            avfilter_inout_free(&openInputs)
            avfilter_inout_free(&openOutputs)
        }
        guard let chainInputs = openInputs, let chainOutputs = openOutputs else { throw VideoEngineError.outOfMemory }
        chainOutputs.pointee.name = av_strdup("in")
        chainOutputs.pointee.filter_ctx = sourceContext
        chainOutputs.pointee.pad_idx = 0
        chainOutputs.pointee.next = nil
        chainInputs.pointee.name = av_strdup("out")
        chainInputs.pointee.filter_ctx = sinkContext
        chainInputs.pointee.pad_idx = 0
        chainInputs.pointee.next = nil
        result = avfilter_graph_parse_ptr(graph, chain, &openInputs, &openOutputs, nil)
        guard result >= 0 else { throw VideoEngineError.failure("parse audio filters", result) }
        result = avfilter_graph_config(graph, nil)
        guard result >= 0 else { throw VideoEngineError.failure("configure audio filters", result) }
        succeeded = true
        return (graph, sourceContext, sinkContext)
    }

    /// Feeds a decoded frame, or nil at the end of the stream, and hands each frame the graph has ready
    /// to `deliver`. A frame is only valid inside `deliver`.
    func push(_ frame: UnsafeMutablePointer<AVFrame>?, deliver: (UnsafeMutablePointer<AVFrame>) throws -> Void) throws {
        if let frame {
            frame.pointee.pts = fed
            fed += Int64(frame.pointee.nb_samples)
        }
        let added = av_buffersrc_add_frame_flags(source, frame, 0)
        guard added >= 0 else { throw VideoEngineError.failure("filter audio", added) }
        while true {
            let received = av_buffersink_get_frame(sink, shaped.pointer)
            if received == FF.eagain || received == FF.averrorEOF { return }
            guard received >= 0 else { throw VideoEngineError.failure("filter audio", received) }
            defer { av_frame_unref(shaped.pointer) }
            try deliver(shaped.pointer)
        }
    }
}
