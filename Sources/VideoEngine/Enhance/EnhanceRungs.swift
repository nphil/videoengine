import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal
// The iOS simulator's SDK has no MetalFX module and declares none of VideoToolbox's frame processors, so the two Apple
// scalers are compiled for devices only; there the simulator reports them as unavailable and the ladder moves on.
#if canImport(MetalFX)
@preconcurrency import MetalFX
#endif
#if !targetEnvironment(simulator)
@preconcurrency import VideoToolbox
#endif

/// The player's frame as the GPU reads it, which every scaler starts from.
struct PlayerPicture {
    var luma: any MTLTexture
    var chroma: any MTLTexture
    var matrix: YCbCrMatrix
    var fullRange: Bool
    /// The window of the frame that is shown and how it is turned: what makes the player's frame the upright picture.
    var geometry: IngestGeometry = .identity

    var coefficients: IngestCoefficients { IngestCoefficients(matrix: matrix, fullRange: fullRange) }
}

/// What a scaler is given for one frame.
struct RungFrame {
    var gpu: EnhanceGPU
    var player: PlayerPicture
    /// The rung's own storage for the picture it reads: filled from the player's frame by `ingestSource`, or by the
    /// rung itself when it takes another format.
    var source: Surface
    var scaled: Surface
    var time: CMTime
    var sequence: Int

    /// Turns the player's NV12 frame into the upright BGRA picture the rung reads, cropped and turned as it is shown.
    func ingestSource(into commands: any MTLCommandBuffer) throws {
        try gpu.ingest(
            player.coefficients, geometry: player.geometry, luma: player.luma, chroma: player.chroma, output: source.texture,
            commands: commands
        )
    }
}

/// A rung that is left out on purpose, and why: it can work, but not for live video on this picture.
struct EnhanceSkip: Error, CustomStringConvertible, Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// One way of making the picture larger. A rung owns the places its own pictures live, because what suits a scaler
/// differs: VideoToolbox reads and writes pixel buffers, the others work on private textures.
protocol ScalerRung: AnyObject, Sendable {
    var kind: EnhanceUpscalerKind { get }
    /// The size of the picture it makes.
    var output: PixelSize { get }
    /// Where the rung keeps the picture it reads.
    var sources: any SurfaceSource { get }
    /// Where the scaler writes the larger picture.
    var scaled: any SurfaceSource { get }
    /// What the device said while the rung was set up, for the probe line.
    var notes: [(String, String)] { get }
    /// Adds the whole job to the frame's command buffer: the picture in, the scaling, and the larger picture out as
    /// BGRA. Returns the BGRA texture the rest of the chain reads.
    func encode(_ frame: RungFrame, into commands: any MTLCommandBuffer) throws -> any MTLTexture
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
        case .metalFXSpatial:
            #if canImport(MetalFX)
            return try MetalFXRung(request)
            #else
            throw EnhanceFailure("this SDK has no MetalFX")
            #endif
        case .videoToolboxLowLatency:
            #if targetEnvironment(simulator)
            throw EnhanceFailure("the simulator has no VideoToolbox frame processor")
            #else
            return try VideoToolboxRung.lowLatency(request)
            #endif
        case .videoToolboxSuperResolution:
            #if targetEnvironment(simulator)
            throw EnhanceFailure("the simulator has no VideoToolbox frame processor")
            #else
            return try VideoToolboxRung.quality(request)
            #endif
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

    func encode(_ frame: RungFrame, into commands: any MTLCommandBuffer) throws -> any MTLTexture {
        try frame.ingestSource(into: commands)
        guard let stretched else {
            try gpu.lanczos(plan, input: frame.source.texture, output: frame.scaled.texture, commands: commands)
            return frame.scaled.texture
        }
        try gpu.lanczos(plan, input: frame.source.texture, output: stretched, commands: commands)
        try gpu.lineArt(
            LineArtParameters(strength: Self.lineArtStrength), input: stretched, output: frame.scaled.texture, commands: commands
        )
        return frame.scaled.texture
    }
}

#if canImport(MetalFX)
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

    func encode(_ frame: RungFrame, into commands: any MTLCommandBuffer) throws -> any MTLTexture {
        try frame.ingestSource(into: commands)
        scaler.colorTexture = frame.source.texture
        scaler.outputTexture = frame.scaled.texture
        scaler.inputContentWidth = input.width
        scaler.inputContentHeight = input.height
        scaler.encode(commandBuffer: commands)
        return frame.scaled.texture
    }
}
#endif

#if !targetEnvironment(simulator)
/// VideoToolbox's machine-learning super resolution, in its quality and its low-latency form. Both read and write the
/// pixel buffers their configuration describes, in a format the configuration reports at run time: BGRA when it takes
/// that, otherwise 420v, the player's own format. The player's frame is then copied in as it is, and the scaled 420v
/// picture is turned into BGRA on the GPU for the rest of the chain.
final class VideoToolboxRung: ScalerRung, @unchecked Sendable {
    private enum Flavor {
        case quality
        case lowLatency
    }

    /// How the picture goes in and out of the scaler.
    private struct Formats {
        var source: ScalerFormat
        var scaled: ScalerFormat
    }

    let kind: EnhanceUpscalerKind
    let output: PixelSize
    let sources: any SurfaceSource
    let scaled: any SurfaceSource
    let notes: [(String, String)]
    private let flavor: Flavor
    private let gpu: EnhanceGPU
    private let formats: Formats
    /// Only when the scaler writes 420v: the BGRA picture made from it, which the rest of the chain reads.
    private let converted: (any MTLTexture)?
    private let processor = VTFrameProcessor()
    private var started = false
    /// The last frame handed to the quality scaler, which uses it to keep the picture steady from frame to frame.
    private var previous: (source: VTFrameProcessorFrame, output: VTFrameProcessorFrame, sequence: Int)?

    private init(
        kind: EnhanceUpscalerKind, flavor: Flavor, gpu: EnhanceGPU, formats: Formats, output: PixelSize, sources: PooledSurfaces,
        scaled: PooledSurfaces, converted: (any MTLTexture)?, notes: [(String, String)]
    ) {
        self.kind = kind
        self.flavor = flavor
        self.gpu = gpu
        self.formats = formats
        self.output = output
        self.sources = sources
        self.scaled = scaled
        self.converted = converted
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
        let verdict = EnhanceMath.fixedFactor(needed: request.needed, source: source, from: offered.map { Double($0) }, fits: { candidate in
            let scale = Float(candidate)
            if let limit = Configuration.maximumDimension(forSpatialScaleFactor: scale), max(source.width, source.height) > limit {
                return false
            }
            if let limit = Configuration.maximumPixelCount(forSpatialScaleFactor: scale), source.pixels > limit {
                return false
            }
            return true
        })
        let factor = try chosen(verdict)
        let configuration = Configuration(frameWidth: source.width, frameHeight: source.height, scaleFactor: Float(factor))
        return try build(
            kind: .videoToolboxLowLatency, flavor: .lowLatency, configuration: configuration,
            supported: configuration.supportedPixelFormats, factor: factor, extra: [], request: request
        )
    }

    static func quality(_ request: RungRequest) throws -> VideoToolboxRung {
        typealias Configuration = VTSuperResolutionScalerConfiguration
        guard Configuration.isSupported else { throw EnhanceFailure("it is not supported on this device") }
        let source = request.source
        let offered = Configuration.supportedScaleFactors
        let factor = try chosen(EnhanceMath.fixedFactor(needed: request.needed, source: source, from: offered.map { Double($0) }))
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
            supported: configuration.supportedPixelFormats, factor: factor, extra: [("model", describe(model))], request: request
        )
    }

    private static func chosen(_ verdict: EnhanceMath.FactorVerdict) throws -> Double {
        switch verdict {
        case .use(let factor): return factor
        case .skip(let reason): throw EnhanceSkip(reason)
        }
    }

    private static func build(
        kind: EnhanceUpscalerKind, flavor: Flavor, configuration: any VTFrameProcessorConfiguration, supported: [OSType],
        factor: Double, extra: [(String, String)], request: RungRequest
    ) throws -> VideoToolboxRung {
        let sourceAttributes: [String: Any] = configuration.sourcePixelBufferAttributes
        let destinationAttributes: [String: Any] = configuration.destinationPixelBufferAttributes
        // What the scaler takes is read off it here, never assumed: the formats it reports for its input and its output.
        let takenIn = EnhanceFormats.offered(attributes: sourceAttributes, supported: supported)
        let takenOut = EnhanceFormats.offered(attributes: destinationAttributes, supported: supported)
        guard let formatIn = EnhanceFormats.choose(takenIn), let formatOut = EnhanceFormats.choose(takenOut) else {
            throw EnhanceFailure(
                "it takes \(EnhanceFormats.describe(takenIn)) in and \(EnhanceFormats.describe(takenOut)) out, and the engine converts only BGRA and 420v"
            )
        }
        // The scaler says how big its pictures are; trust that over our own arithmetic.
        let expected = EnhanceMath.scaled(request.source, by: factor)
        let width = (destinationAttributes[kCVPixelBufferWidthKey as String] as? Int) ?? expected.width
        let height = (destinationAttributes[kCVPixelBufferHeightKey as String] as? Int) ?? expected.height
        let output = PixelSize(width: width, height: height)
        let usage = EnhanceRungs.usage(including: [])
        guard let sources = PooledSurfaces(
                  size: request.source, format: formatIn, requirements: sourceAttributes, usage: usage, minimum: 2, ceiling: 4,
                  cache: request.gpu.cache),
              let scaled = PooledSurfaces(
                  size: output, format: formatOut, requirements: destinationAttributes, usage: usage, minimum: 2, ceiling: 4,
                  cache: request.gpu.cache)
        else { throw EnhanceFailure("no memory for the scaler's buffers") }
        var converted: (any MTLTexture)?
        if formatOut != .bgra {
            converted = request.gpu.makeTexture(output, format: .bgra8Unorm)
            if converted == nil { throw EnhanceFailure("no memory for the scaler's textures") }
        }
        var notes: [(String, String)] = [
            ("scale", EnhanceMath.factorText(factor)), ("formats", EnhanceFormats.describe(supported)),
            ("in", formatIn.name), ("out", formatOut.name),
        ]
        notes.append(contentsOf: extra)
        let rung = VideoToolboxRung(
            kind: kind, flavor: flavor, gpu: request.gpu, formats: Formats(source: formatIn, scaled: formatOut), output: output,
            sources: sources, scaled: scaled, converted: converted, notes: notes
        )
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

    func encode(_ frame: RungFrame, into commands: any MTLCommandBuffer) throws -> any MTLTexture {
        switch formats.source {
        case .bgra:
            try frame.ingestSource(into: commands)
        case .nv12VideoRange:
            // The player's frames are 420v already (the output asks for it), so they only need to land, cropped and turned
            // upright, in a buffer made to the scaler's own requirements.
            guard !frame.player.fullRange, let chroma = frame.source.chroma else {
                throw EnhanceFailure("the scaler takes 420v pictures and this frame is not video range")
            }
            try frame.gpu.reorient(
                frame.player.geometry, luma: frame.player.luma, chroma: frame.player.chroma, toLuma: frame.source.texture,
                toChroma: chroma, commands: commands
            )
        }
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
        switch formats.scaled {
        case .bgra:
            return frame.scaled.texture
        case .nv12VideoRange:
            guard let converted, let chroma = frame.scaled.chroma else {
                throw EnhanceFailure("no BGRA picture to convert the scaler's 420v output into")
            }
            // The scaler keeps the video's own matrix and range.
            let coefficients = IngestCoefficients(matrix: frame.player.matrix, fullRange: false)
            try gpu.ingest(coefficients, luma: frame.scaled.texture, chroma: chroma, output: converted, commands: commands)
            return converted
        }
    }
}
#endif
