import CoreGraphics
import Foundation
import Libavcodec
import Libavutil
import Libswscale

/// The sizes of one picture: what the scaler writes, and what comes out after any quarter turn.
struct FrameLayout {
    /// The scaler's output: the picture before it is turned upright.
    let scaledWidth: Int
    let scaledHeight: Int
    /// The finished picture.
    let width: Int
    let height: Int

    /// `pixelAspect` is the shape of one pixel and `degrees` the clockwise turn that stands the picture upright.
    /// The picture takes its real proportions by shrinking one side, never by growing the other, and is then
    /// shrunk to fit `maxWidth` and the pixel cap. It is never enlarged.
    init(sourceWidth: Int, sourceHeight: Int, pixelAspect: AVRational, degrees: Int, maxWidth: Int) {
        var shownWidth = Double(sourceWidth)
        var shownHeight = Double(sourceHeight)
        let ratio = Double(pixelAspect.num) / Double(pixelAspect.den)
        if ratio > 1 {
            shownHeight /= ratio
        } else if ratio > 0 {
            shownWidth *= ratio
        }
        let turned = degrees == 90 || degrees == 270
        let uprightWidth = turned ? shownHeight : shownWidth
        let uprightHeight = turned ? shownWidth : shownHeight
        var scale = min(1, Double(maxWidth) / uprightWidth)
        let area = uprightWidth * uprightHeight * scale * scale
        if area > Double(FrameLimits.outputPixels) {
            scale *= (Double(FrameLimits.outputPixels) / area).squareRoot()
        }
        let finishedWidth = max(1, Int((uprightWidth * scale).rounded()))
        let finishedHeight = max(1, Int((uprightHeight * scale).rounded()))
        width = finishedWidth
        height = finishedHeight
        scaledWidth = turned ? finishedHeight : finishedWidth
        scaledHeight = turned ? finishedWidth : finishedHeight
    }
}

/// Turns decoded frames into small 8-bit BGRA pictures: scaled, converted with the video's own colour matrix and
/// range, reshaped for its pixel aspect ratio and turned upright. Keeps its scaler between frames. Used only from
/// the worker queue.
final class FrameRenderer {
    /// swscale's coefficient set for BT.601, the one it uses for the RGB side.
    private static let defaultMatrix: Int32 = 5

    private let stream: UnsafeMutablePointer<AVStream>
    /// The clockwise turn that stands the picture upright, from the container: 0, 90, 180 or 270.
    private let rotation: Int
    private var scaler: UnsafeMutablePointer<SwsContext>?

    init(stream: UnsafeMutablePointer<AVStream>) {
        self.stream = stream
        rotation = Self.displayRotation(of: stream)
    }

    deinit { sws_freeContext(scaler) }

    /// The picture in `decoded`, which stays the caller's.
    func image(from decoded: UnsafeMutablePointer<AVFrame>, maxWidth: Int) throws -> CGImage {
        var transferred: FFFrame?
        if decoded.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // A VideoToolbox frame is a GPU surface: copy it to memory to scale it.
            let copy = try FFFrame()
            let result = av_hwframe_transfer_data(copy.pointer, decoded, 0)
            guard result >= 0 else { throw VideoEngineError.failure("hardware frame transfer", result) }
            transferred = copy
        }
        return try withExtendedLifetime(transferred) {
            try render(transferred?.pointer ?? decoded, maxWidth: maxWidth)
        }
    }

    private func render(_ source: UnsafeMutablePointer<AVFrame>, maxWidth: Int) throws -> CGImage {
        let width = Int(source.pointee.width)
        let height = Int(source.pointee.height)
        guard width > 0, height > 0, width * height <= FrameLimits.sourcePixels else {
            throw VideoEngineError.unsupportedSource("the pictures are larger than 8K")
        }
        let layout = FrameLayout(
            sourceWidth: width, sourceHeight: height, pixelAspect: pixelAspect(of: source), degrees: rotation,
            maxWidth: maxWidth
        )
        scaler = sws_getCachedContext(
            scaler, source.pointee.width, source.pointee.height, AVPixelFormat(rawValue: source.pointee.format),
            Int32(layout.scaledWidth), Int32(layout.scaledHeight), AV_PIX_FMT_BGRA, FF.swsArea, nil, nil, nil
        )
        guard scaler != nil else { throw VideoEngineError.failure("scaler setup", FF.einval) }
        // The scaler takes the YUV matrix and range from its own setup, not from the frame, and a cached scaler
        // may last have served a video with other ones, so set them for every frame. RGB sources have none to set.
        _ = sws_setColorspaceDetails(
            scaler, sws_getCoefficients(Self.matrix(for: source)), Self.isFullRange(source) ? 1 : 0,
            sws_getCoefficients(Self.defaultMatrix), 1, 0, 1 << 16, 1 << 16
        )
        let scaled = try Self.makeFrame(width: layout.scaledWidth, height: layout.scaledHeight)
        let converted = sws_scale_frame(scaler, scaled.pointer, source)
        guard converted >= 0 else { throw VideoEngineError.failure("scale", converted) }
        let upright = try rotation == 0 ? scaled : Self.rotated(scaled, byDegrees: rotation)
        return try Self.cgImage(from: upright)
    }

    /// The shape of one pixel: the container's word first, as FFmpeg's own tools take it, then the codec's.
    private func pixelAspect(of frame: UnsafeMutablePointer<AVFrame>) -> AVRational {
        for candidate in [stream.pointee.sample_aspect_ratio, frame.pointee.sample_aspect_ratio]
        where candidate.num > 0 && candidate.den > 0 {
            return candidate
        }
        return AVRational(num: 1, den: 1)
    }

    /// swscale's coefficient set for the frame's YUV matrix. Untagged video follows the usual rule: BT.709 from 720
    /// lines up, BT.601 below.
    private static func matrix(for frame: UnsafeMutablePointer<AVFrame>) -> Int32 {
        switch frame.pointee.colorspace {
        case AVCOL_SPC_BT709: return 1
        case AVCOL_SPC_FCC: return 4
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M: return 5
        case AVCOL_SPC_SMPTE240M: return 7
        case AVCOL_SPC_BT2020_NCL, AVCOL_SPC_BT2020_CL: return 9
        default: return frame.pointee.height >= 720 ? 1 : 5
        }
    }

    private static func isFullRange(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        if frame.pointee.color_range == AVCOL_RANGE_JPEG { return true }
        // Full range the old way: in the pixel format instead of the frame.
        switch AVPixelFormat(rawValue: frame.pointee.format) {
        case AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_YUVJ440P, AV_PIX_FMT_YUVJ411P:
            return true
        default:
            return false
        }
    }

    /// The clockwise turn that stands the video upright (0, 90, 180 or 270), from the stream's display matrix.
    /// Mirroring and turns that are not quarter turns are ignored.
    private static func displayRotation(of stream: UnsafeMutablePointer<AVStream>) -> Int {
        guard let parameters = stream.pointee.codecpar,
              let side = av_packet_side_data_get(
                  parameters.pointee.coded_side_data, parameters.pointee.nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX
              ),
              side.pointee.size >= 9 * MemoryLayout<Int32>.size, let data = side.pointee.data
        else { return 0 }
        // FFmpeg reports the angle the matrix turns the picture counterclockwise; upright is the opposite turn.
        let clockwise = -av_display_rotation_get(UnsafeRawPointer(data).assumingMemoryBound(to: Int32.self))
        guard clockwise.isFinite else { return 0 }
        return (Int((clockwise / 90).rounded()) % 4 + 4) % 4 * 90
    }

    private static func makeFrame(width: Int, height: Int) throws -> FFFrame {
        let frame = try FFFrame()
        frame.pointer.pointee.format = AV_PIX_FMT_BGRA.rawValue
        frame.pointer.pointee.width = Int32(width)
        frame.pointer.pointee.height = Int32(height)
        let allocated = av_frame_get_buffer(frame.pointer, 0)
        guard allocated >= 0 else { throw VideoEngineError.failure("frame buffer", allocated) }
        return frame
    }

    /// A copy of a BGRA frame turned clockwise by `degrees`: 90, 180 or 270.
    private static func rotated(_ frame: FFFrame, byDegrees degrees: Int) throws -> FFFrame {
        let sourceWidth = Int(frame.pointer.pointee.width)
        let sourceHeight = Int(frame.pointer.pointee.height)
        let turned = degrees != 180
        let outputWidth = turned ? sourceHeight : sourceWidth
        let outputHeight = turned ? sourceWidth : sourceHeight
        let output = try makeFrame(width: outputWidth, height: outputHeight)
        guard let from = frame.pointer.pointee.data.0, let to = output.pointer.pointee.data.0 else {
            throw VideoEngineError.outOfMemory
        }
        // One pixel is one 32-bit word; every stride is a whole number of them.
        let sourceStride = Int(frame.pointer.pointee.linesize.0) / 4
        let outputStride = Int(output.pointer.pointee.linesize.0) / 4
        let source = UnsafeRawPointer(from).assumingMemoryBound(to: UInt32.self)
        let target = UnsafeMutableRawPointer(to).assumingMemoryBound(to: UInt32.self)
        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let sourceX: Int
                let sourceY: Int
                switch degrees {
                case 90:
                    sourceX = y
                    sourceY = sourceHeight - 1 - x
                case 180:
                    sourceX = sourceWidth - 1 - x
                    sourceY = sourceHeight - 1 - y
                default:
                    sourceX = sourceWidth - 1 - y
                    sourceY = x
                }
                target[y * outputStride + x] = source[sourceY * sourceStride + sourceX]
            }
        }
        return output
    }

    /// An image over the frame's own pixels, which the image keeps alive: nothing is copied.
    private static func cgImage(from frame: FFFrame) throws -> CGImage {
        let width = Int(frame.pointer.pointee.width)
        let height = Int(frame.pointer.pointee.height)
        let stride = Int(frame.pointer.pointee.linesize.0)
        guard let pixels = frame.pointer.pointee.data.0 else { throw VideoEngineError.outOfMemory }
        let owner = Unmanaged.passRetained(frame)
        guard let provider = CGDataProvider(
            dataInfo: owner.toOpaque(), data: pixels, size: stride * height,
            releaseData: { info, _, _ in
                if let info { Unmanaged<FFFrame>.fromOpaque(info).release() }
            }
        ) else {
            owner.release()
            throw VideoEngineError.outOfMemory
        }
        // BGRA in memory is a little-endian 32-bit word with the unused alpha byte first.
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                  space: space, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else { throw VideoEngineError.outOfMemory }
        return image
    }
}
