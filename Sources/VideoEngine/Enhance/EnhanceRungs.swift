import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal
@preconcurrency import MetalFX
@preconcurrency import VideoToolbox

/// What a scaler is given for one frame.
struct RungFrame {
    var source: Surface
    var scaled: Surface
    var time: CMTime
    var sequence: Int
}

/// One way of making the picture larger. A rung owns the places its own pictures live, because what suits a scaler
/// differs: VideoToolbox reads and writes pixel buffers, the others work on private textures.
protocol ScalerRung: AnyObject, Sendable {
    var kind: EnhanceUpscalerKind { get }
    /// The size of the picture it makes.
    var output: PixelSize { get }
    /// Where the ingest writes the BGRA picture the scaler reads.
    var sources: any SurfaceSource { get }
    /// Where the scaler writes the larger picture.
    var scaled: any SurfaceSource { get }
    /// What the device said while the rung was set up, for the probe line.
    var notes: [(String, String)] { get }
    /// Adds the scaling work to the frame's command buffer.
    func encode(_ frame: RungFrame, into commands: any MTLCommandBuffer) throws
}

struct RungRequest: Sendable {
    var kind: EnhanceUpscalerKind
    var gpu: EnhanceGPU
    var source: PixelSize
    /// The scale that makes the picture just fit the display.
    var needed: Double
}

enum EnhanceRungs {
    /// Builds a rung, which can take a while (VideoToolbox loads a model), so call this off the main thread.
    /// Throws a reason a person can read when the rung cannot work here.
    static func make(_ request: RungRequest) throws -> any ScalerRung {
        switch request.kind {
        case .lanczos: return try LanczosRung(request, steepen: false)
        case .lineArt: return try LanczosRung(request, steepen: true)
        case .metalFXSpatial: return try MetalFXRung(request)
        case .videoToolboxLowLatency: return try VideoToolboxRung.lowLatency(request)
        case .videoToolboxSuperResolution: return try VideoToolboxRung.quality(request)
        }
    }

    /// The usage a texture needs for our own passes plus what a scaler asks of it.
    static func usage(including extra: MTLTextureUsage) -> MTLTextureUsage {
        var usage: MTLTextureUsage = [.shaderRead, .shaderWrite]
        usage.formUnion(extra)
        return usage
    }

    static func fourCC(_ code: OSType) -> String {
        var bytes: [UInt8] = []
        let shifts: [UInt32] = [24, 16, 8, 0]
        for shift in shifts {
            bytes.append(UInt8((code >> shift) & 0xFF))
        }
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        return printable ? String(decoding: bytes, as: UTF8.self) : String(code)
    }
}

/// The engine's own scaler: Lanczos-3, and for line art the same followed by an edge-thinning pass.
final class LanczosRung: ScalerRung, @unchecked Sendable {
    static let lineArtStrength: Float = 0.75

    let kind: EnhanceUpscalerKind
    let output: PixelSize
    let sources: any SurfaceSource
    let scaled: any SurfaceSource
    let notes: [(String, String)] = []
    private let gpu: EnhanceGPU
    private let plan: LanczosPlan
    /// Line art only: the Lanczos result before the edges are thinned.
    private let stretched: (any MTLTexture)?

    init(_ request: RungRequest, steepen: Bool) throws {
        guard let output = EnhanceMath.freeOutput(source: request.source, scale: request.needed) else {
            throw EnhanceFailure("no scale is worth a pass here")
        }
        let gpu = request.gpu
        guard let plan = gpu.makeLanczosPlan(source: request.source, output: output),
              let sources = PrivateSurfaces(device: gpu.device, size: request.source),
              let scaled = PrivateSurfaces(device: gpu.device, size: output)
        else { throw EnhanceFailure("no memory for the scaler's textures") }
        var stretched: (any MTLTexture)?
        if steepen {
            stretched = gpu.makeTexture(output, format: .bgra8Unorm)
            if stretched == nil { throw EnhanceFailure("no memory for the scaler's textures") }
        }
        self.kind = request.kind
        self.output = output
        self.sources = sources
        self.scaled = scaled
        self.gpu = gpu
        self.plan = plan
        self.stretched = stretched
    }

    func encode(_ frame: RungFrame, into commands: any MTLCommandBuffer) throws {
        guard let stretched else {
            try gpu.lanczos(plan, input: frame.source.texture, output: frame.scaled.texture, commands: commands)
            return
        }
        try gpu.lanczos(plan, input: frame.source.texture, output: stretched, commands: commands)
        try gpu.lineArt(
            LineArtParameters(strength: Self.lineArtStrength), input: stretched, output: frame.scaled.texture, commands: commands
        )
    }
}

/// MetalFX's spatial scaler.
final class MetalFXRung: ScalerRung, @unchecked Sendable {
    let kind = EnhanceUpscalerKind.metalFXSpatial
    let output: PixelSize
    let sources: any SurfaceSource
    let scaled: any SurfaceSource
    let notes: [(String, String)] = []
    private let scaler: any MTLFXSpatialScaler
    private let input: PixelSize

    init(_ request: RungRequest) throws {
        let gpu = request.gpu
        guard MTLFXSpatialScalerDescriptor.supportsDevice(gpu.device) else {
            throw EnhanceFailure("this GPU does not support MetalFX")
        }
        guard let output = EnhanceMath.freeOutput(source: request.source, scale: request.needed) else {
            throw EnhanceFailure("no scale is worth a pass here")
        }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = request.source.width
        descriptor.inputHeight = request.source.height
        descriptor.outputWidth = output.width
        descriptor.outputHeight = output.height
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard let scaler = descriptor.makeSpatialScaler(device: gpu.device) else {
            throw EnhanceFailure("MetalFX would not make a scaler from \(request.source) to \(output)")
        }
        let sourceUsage = EnhanceRungs.usage(including: scaler.colorTextureUsage)
        let scaledUsage = EnhanceRungs.usage(including: scaler.outputTextureUsage)
        guard let sources = PrivateSurfaces(device: gpu.device, size: request.source, usage: sourceUsage),
              let scaled = PrivateSurfaces(device: gpu.device, size: output, usage: scaledUsage)
        else { throw EnhanceFailure("no memory for the scaler's textures") }
        self.output = output
        self.sources = sources
        self.scaled = scaled
        self.scaler = scaler
        self.input = request.source
    }

    func encode(_ frame: RungFrame, into commands: any MTLCommandBuffer) throws {
        scaler.colorTexture = frame.source.texture
        scaler.outputTexture = frame.scaled.texture
        scaler.inputContentWidth = input.width
        scaler.inputContentHeight = input.height
        scaler.encode(commandBuffer: commands)
    }
}

/// VideoToolbox's machine-learning super resolution, in its quality and its low-latency form. Both read and write
/// BGRA pixel buffers from pools whose attributes the scaler itself dictates.
final class VideoToolboxRung: ScalerRung, @unchecked Sendable {
    private enum Flavor {
        case quality
        case lowLatency
    }

    let kind: EnhanceUpscalerKind
    let output: PixelSize
    let sources: any SurfaceSource
    let scaled: any SurfaceSource
    let notes: [(String, String)]
    private let flavor: Flavor
    private let processor = VTFrameProcessor()
    private var started = false
    /// The last frame handed to the quality scaler, which uses it to keep the picture steady from frame to frame.
    private var previous: (source: VTFrameProcessorFrame, output: VTFrameProcessorFrame, sequence: Int)?

    private init(
        kind: EnhanceUpscalerKind, flavor: Flavor, output: PixelSize, sources: PooledSurfaces, scaled: PooledSurfaces,
        notes: [(String, String)]
    ) {
        self.kind = kind
        self.flavor = flavor
        self.output = output
        self.sources = sources
        self.scaled = scaled
        self.notes = notes
    }

    deinit {
        if started { processor.endSession() }
    }

    static func lowLatency(_ request: RungRequest) throws -> VideoToolboxRung {
        typealias Configuration = VTLowLatencySuperResolutionScalerConfiguration
        guard Configuration.isSupported else { throw EnhanceFailure("it is not supported on this device") }
        let source = request.source
        let offered = Configuration.supportedScaleFactors(frameWidth: source.width, frameHeight: source.height)
        let chosen = EnhanceMath.factor(needed: request.needed, source: source, from: offered.map { Double($0) }, fits: { candidate in
            let scale = Float(candidate)
            if let limit = Configuration.maximumDimension(forSpatialScaleFactor: scale), max(source.width, source.height) > limit {
                return false
            }
            if let limit = Configuration.maximumPixelCount(forSpatialScaleFactor: scale), source.pixels > limit {
                return false
            }
            return true
        })
        guard let factor = chosen else { throw EnhanceFailure("no scale factor fits a \(source) picture (it offers \(offered))") }
        let configuration = Configuration(frameWidth: source.width, frameHeight: source.height, scaleFactor: Float(factor))
        return try build(
            kind: .videoToolboxLowLatency, flavor: .lowLatency, configuration: configuration,
            formats: configuration.supportedPixelFormats, factor: factor, extra: [], request: request
        )
    }

    static func quality(_ request: RungRequest) throws -> VideoToolboxRung {
        typealias Configuration = VTSuperResolutionScalerConfiguration
        guard Configuration.isSupported else { throw EnhanceFailure("it is not supported on this device") }
        let source = request.source
        let offered = Configuration.supportedScaleFactors
        let chosen = EnhanceMath.factor(needed: request.needed, source: source, from: offered.map { Double($0) })
        guard let factor = chosen else { throw EnhanceFailure("no scale factor fits a \(source) picture (it offers \(offered))") }
        guard let configuration = Configuration(
            frameWidth: source.width, frameHeight: source.height, scaleFactor: Int(factor), inputType: .video,
            usePrecomputedFlow: false, qualityPrioritization: .normal, revision: Configuration.defaultRevision
        ) else { throw EnhanceFailure("it refused a \(source) picture at \(Int(factor))x") }
        let model = configuration.configurationModelStatus
        guard model == .ready else {
            throw EnhanceFailure("its model is not on this device yet (\(describe(model)))")
        }
        return try build(
            kind: .videoToolboxSuperResolution, flavor: .quality, configuration: configuration,
            formats: configuration.supportedPixelFormats, factor: factor, extra: [("model", describe(model))], request: request
        )
    }

    private static func build(
        kind: EnhanceUpscalerKind, flavor: Flavor, configuration: any VTFrameProcessorConfiguration, formats: [OSType],
        factor: Double, extra: [(String, String)], request: RungRequest
    ) throws -> VideoToolboxRung {
        let listed = formats.map { EnhanceRungs.fourCC($0) }.joined(separator: " ")
        guard formats.contains(OSType(kCVPixelFormatType_32BGRA)) else {
            throw EnhanceFailure("it does not take BGRA pictures (it takes \(listed))")
        }
        let sourceAttributes: [String: Any] = configuration.sourcePixelBufferAttributes
        let destinationAttributes: [String: Any] = configuration.destinationPixelBufferAttributes
        // The scaler says how big its pictures are; trust that over our own arithmetic.
        let expected = EnhanceMath.scaled(request.source, by: factor)
        let width = (destinationAttributes[kCVPixelBufferWidthKey as String] as? Int) ?? expected.width
        let height = (destinationAttributes[kCVPixelBufferHeightKey as String] as? Int) ?? expected.height
        let output = PixelSize(width: width, height: height)
        let usage = EnhanceRungs.usage(including: [])
        guard let sources = PooledSurfaces(
                  size: request.source, requirements: sourceAttributes, usage: usage, minimum: 2, ceiling: 4, cache: request.gpu.cache),
              let scaled = PooledSurfaces(
                  size: output, requirements: destinationAttributes, usage: usage, minimum: 2, ceiling: 4, cache: request.gpu.cache)
        else { throw EnhanceFailure("no memory for the scaler's buffers") }
        var notes: [(String, String)] = [("scale", String(factor)), ("formats", listed)]
        notes.append(contentsOf: extra)
        let rung = VideoToolboxRung(kind: kind, flavor: flavor, output: output, sources: sources, scaled: scaled, notes: notes)
        do {
            try rung.processor.startSession(configuration: configuration)
        } catch {
            throw EnhanceFailure("its session would not start: \(error)")
        }
        rung.started = true
        return rung
    }

    private static func describe(_ status: VTSuperResolutionScalerConfiguration.ModelStatus) -> String {
        switch status {
        case .ready: "ready"
        case .downloading: "downloading"
        case .downloadRequired: "download required"
        @unknown default: "unknown"
        }
    }

    func encode(_ frame: RungFrame, into commands: any MTLCommandBuffer) throws {
        guard let sourceBuffer = frame.source.buffer, let scaledBuffer = frame.scaled.buffer,
              let input = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: frame.time),
              let destination = VTFrameProcessorFrame(buffer: scaledBuffer, presentationTimeStamp: frame.time)
        else { throw EnhanceFailure("the scaler refused the frame's buffers") }
        switch flavor {
        case .lowLatency:
            let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: input, destinationFrame: destination)
            processor.process(with: commands, parameters: parameters)
        case .quality:
            var contiguous = false
            if let last = previous { contiguous = last.sequence + 1 == frame.sequence }
            let mode: VTSuperResolutionScalerParameters.SubmissionMode = contiguous ? .sequential : .random
            guard let parameters = VTSuperResolutionScalerParameters(
                sourceFrame: input, previousFrame: contiguous ? previous?.source : nil,
                previousOutputFrame: contiguous ? previous?.output : nil, opticalFlow: nil,
                submissionMode: mode, destinationFrame: destination
            ) else { throw EnhanceFailure("the scaler refused the frame's parameters") }
            previous = (input, destination, frame.sequence)
            processor.process(with: commands, parameters: parameters)
        }
    }
}
