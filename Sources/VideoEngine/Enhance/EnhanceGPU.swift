import CoreVideo
import Foundation
@preconcurrency import Metal

/// The compose kernel's parameter block, laid out as the shader declares it.
struct ComposeParameters {
    var sharpen: Float
    var deband: Float
    var debandRadius: Float
    var debandThreshold: Float
    var frame: UInt32
    /// The vivid strength, 0 for off, and how far it looks for the average brightness, in output pixels.
    var vivid: Float = 0
    var vividRadius: Float = 8
    /// The size of the dither in codes of 255; 0 for none. See `EnhanceMath.ditherCodes`.
    var dither: Float = 0
}

/// The block-edge softening a luma read does, laid out as the shader declares it. `amount` of 0 is off.
struct DeblockParameters: Equatable {
    var step: Float
    var activity: Float
    var amount: Float

    static let off = DeblockParameters(step: 0, activity: 0, amount: 0)
}

extension DeblockParameters {
    init(strength: Double) {
        guard strength > 0 else {
            self = .off
            return
        }
        self.init(
            step: EnhanceMath.deblockStep(strength), activity: EnhanceMath.deblockActivity(strength),
            amount: EnhanceMath.deblockAmount(strength)
        )
    }
}

/// The denoise kernel's parameter block, laid out as the shader declares it. `history` is the most the previous frame
/// may weigh: 0 when there is no usable previous frame.
struct DenoiseParameters: Equatable {
    var range: Float
    var spatial: Float
    var tolerance: Float
    var history: Float

    init(range: Float, spatial: Float, tolerance: Float, history: Float) {
        self.range = range
        self.spatial = spatial
        self.tolerance = tolerance
        self.history = history
    }

    init(strength: Double, remembers: Bool) {
        self.init(
            range: EnhanceMath.denoiseRange(strength), spatial: EnhanceMath.denoiseSpatialAmount(strength),
            tolerance: EnhanceMath.denoiseTolerance(strength), history: remembers ? EnhanceMath.denoiseHistoryWeight(strength) : 0
        )
    }
}

/// The line-art kernel's parameter block, laid out as the shader declares it.
struct LineArtParameters {
    var strength: Float
}

/// The ingest and reorient kernels' geometry block, laid out as the shader declares it: where the shown picture is in
/// the coded frame and how it is turned. See `PictureGeometry`.
struct IngestGeometry: Equatable {
    var cropX: Int32
    var cropY: Int32
    var swapAxes: Int32
    var flipAcross: Int32
    var flipDown: Int32

    /// The whole frame, as it is.
    static let identity = IngestGeometry(cropX: 0, cropY: 0, swapAxes: 0, flipAcross: 0, flipDown: 0)

    init(cropX: Int32, cropY: Int32, swapAxes: Int32, flipAcross: Int32, flipDown: Int32) {
        self.cropX = cropX
        self.cropY = cropY
        self.swapAxes = swapAxes
        self.flipAcross = flipAcross
        self.flipDown = flipDown
    }

    init(_ geometry: PictureGeometry) {
        cropX = Int32(geometry.crop.x)
        cropY = Int32(geometry.crop.y)
        swapAxes = geometry.orientation.swapsAxes ? 1 : 0
        flipAcross = geometry.orientation.flipsAcross ? 1 : 0
        flipDown = geometry.orientation.flipsDown ? 1 : 0
    }
}

/// The taps and the one intermediate texture of a separable scale from one size to another: Lanczos-3 for a scale up
/// (`LanczosTaps`) or Lanczos-2 with eight taps for a scale down (`DownscaleTaps`).
final class LanczosPlan: @unchecked Sendable {
    let source: PixelSize
    let output: PixelSize
    let columnStarts: any MTLBuffer
    let columnWeights: any MTLBuffer
    let rowStarts: any MTLBuffer
    let rowWeights: any MTLBuffer
    /// The picture stretched across but not yet down: `output.width` by `source.height`, in half floats.
    let middle: any MTLTexture

    init(
        source: PixelSize, output: PixelSize, columnStarts: any MTLBuffer, columnWeights: any MTLBuffer,
        rowStarts: any MTLBuffer, rowWeights: any MTLBuffer, middle: any MTLTexture
    ) {
        self.source = source
        self.output = output
        self.columnStarts = columnStarts
        self.columnWeights = columnWeights
        self.rowStarts = rowStarts
        self.rowWeights = rowWeights
        self.middle = middle
    }
}

/// The Metal side of the chain: the device, the compiled kernels and the texture cache. Built once, off the main thread,
/// and shared by every stage; each stage encodes into a command buffer the caller commits.
final class EnhanceGPU: @unchecked Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let cache: CVMetalTextureCache
    private let ingestKernel: any MTLComputePipelineState
    private let horizontalKernel: any MTLComputePipelineState
    private let verticalKernel: any MTLComputePipelineState
    private let lineArtKernel: any MTLComputePipelineState
    private let composeKernel: any MTLComputePipelineState
    private let denoiseKernel: any MTLComputePipelineState
    private let downscaleHorizontalKernel: any MTLComputePipelineState
    private let downscaleVerticalKernel: any MTLComputePipelineState
    private let reorientLumaKernel: any MTLComputePipelineState
    private let reorientChromaKernel: any MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw EnhanceFailure("this device has no Metal GPU") }
        guard let queue = device.makeCommandQueue() else { throw EnhanceFailure("Metal gave no command queue") }
        var created: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &created) == kCVReturnSuccess,
              let cache = created
        else { throw EnhanceFailure("Metal gave no texture cache") }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: EnhanceShaders.source, options: options)
        } catch {
            throw EnhanceFailure("the shaders did not compile: \(error)")
        }
        func kernel(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw EnhanceFailure("no kernel named \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.queue = queue
        self.cache = cache
        ingestKernel = try kernel("ingest_nv12")
        horizontalKernel = try kernel("lanczos_horizontal")
        verticalKernel = try kernel("lanczos_vertical")
        lineArtKernel = try kernel("line_art_steepen")
        composeKernel = try kernel("compose")
        denoiseKernel = try kernel("denoise")
        downscaleHorizontalKernel = try kernel("downscale_horizontal")
        downscaleVerticalKernel = try kernel("downscale_vertical")
        reorientLumaKernel = try kernel("reorient_luma")
        reorientChromaKernel = try kernel("reorient_chroma")
    }

    /// A private texture the GPU uses between passes.
    func makeTexture(_ size: PixelSize, format: MTLPixelFormat, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size.width, height: size.height, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    func makeLanczosPlan(source: PixelSize, output: PixelSize) -> LanczosPlan? {
        let columns = LanczosTaps(source: source.width, output: output.width)
        let rows = LanczosTaps(source: source.height, output: output.height)
        guard let columnStarts = buffer(columns.starts),
              let columnWeights = buffer(columns.weights),
              let rowStarts = buffer(rows.starts),
              let rowWeights = buffer(rows.weights),
              let middle = makeTexture(PixelSize(width: output.width, height: source.height), format: .rgba16Float)
        else { return nil }
        return LanczosPlan(
            source: source, output: output, columnStarts: columnStarts, columnWeights: columnWeights,
            rowStarts: rowStarts, rowWeights: rowWeights, middle: middle
        )
    }

    /// The taps and intermediate texture for scaling a picture down, `output` smaller than `source` and at least half its size.
    func makeDownscalePlan(source: PixelSize, output: PixelSize) -> LanczosPlan? {
        let columns = DownscaleTaps(source: source.width, output: output.width)
        let rows = DownscaleTaps(source: source.height, output: output.height)
        guard let columnStarts = buffer(columns.starts),
              let columnWeights = buffer(columns.weights),
              let rowStarts = buffer(rows.starts),
              let rowWeights = buffer(rows.weights),
              let middle = makeTexture(PixelSize(width: output.width, height: source.height), format: .rgba16Float)
        else { return nil }
        return LanczosPlan(
            source: source, output: output, columnStarts: columnStarts, columnWeights: columnWeights,
            rowStarts: rowStarts, rowWeights: rowWeights, middle: middle
        )
    }

    /// Video-range or full-range NV12 into BGRA, using the video's own matrix. The output is the upright picture, so
    /// its size is the crop's, with the sides swapped for a quarter turn; `geometry` says which window of the frame it is
    /// and how it is turned. `deblock` softens block edges in the luma before the colour is made; leave it off for a
    /// picture that was not coded in blocks, such as a scaler's result.
    func ingest(
        _ coefficients: IngestCoefficients, geometry: IngestGeometry = .identity, deblock: DeblockParameters = .off,
        luma: any MTLTexture, chroma: any MTLTexture, output: any MTLTexture, commands: any MTLCommandBuffer
    ) throws {
        try dispatch(commands, ingestKernel, width: output.width, height: output.height) { encoder in
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(output, index: 2)
            Self.bind(encoder, coefficients, index: 0)
            Self.bind(encoder, geometry, index: 1)
            Self.bind(encoder, deblock, index: 2)
        }
    }

    /// Crops and turns one NV12 picture into another that stays NV12, which is what a scaler that takes only 420v reads.
    /// The destination planes are the upright picture's size and even. `deblock` softens block edges in the luma.
    func reorient(
        _ geometry: IngestGeometry, deblock: DeblockParameters = .off, luma: any MTLTexture, chroma: any MTLTexture, toLuma: any MTLTexture, toChroma: any MTLTexture,
        commands: any MTLCommandBuffer
    ) throws {
        try dispatch(commands, reorientLumaKernel, width: toLuma.width, height: toLuma.height) { encoder in
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(toLuma, index: 1)
            Self.bind(encoder, geometry, index: 0)
            Self.bind(encoder, deblock, index: 1)
        }
        try dispatch(commands, reorientChromaKernel, width: toChroma.width, height: toChroma.height) { encoder in
            encoder.setTexture(chroma, index: 0)
            encoder.setTexture(toChroma, index: 1)
            Self.bind(encoder, geometry, index: 0)
        }
    }

    /// Lanczos-3 across, then down.
    func lanczos(_ plan: LanczosPlan, input: any MTLTexture, output: any MTLTexture, commands: any MTLCommandBuffer) throws {
        try dispatch(commands, horizontalKernel, width: plan.output.width, height: plan.source.height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(plan.middle, index: 1)
            encoder.setBuffer(plan.columnStarts, offset: 0, index: 0)
            encoder.setBuffer(plan.columnWeights, offset: 0, index: 1)
        }
        try dispatch(commands, verticalKernel, width: plan.output.width, height: plan.output.height) { encoder in
            encoder.setTexture(plan.middle, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBuffer(plan.rowStarts, offset: 0, index: 0)
            encoder.setBuffer(plan.rowWeights, offset: 0, index: 1)
        }
    }

    /// Scales a picture down with Lanczos-2: across, then down.
    func downscale(_ plan: LanczosPlan, input: any MTLTexture, output: any MTLTexture, commands: any MTLCommandBuffer) throws {
        try dispatch(commands, downscaleHorizontalKernel, width: plan.output.width, height: plan.source.height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(plan.middle, index: 1)
            encoder.setBuffer(plan.columnStarts, offset: 0, index: 0)
            encoder.setBuffer(plan.columnWeights, offset: 0, index: 1)
        }
        try dispatch(commands, downscaleVerticalKernel, width: plan.output.width, height: plan.output.height) { encoder in
            encoder.setTexture(plan.middle, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBuffer(plan.rowStarts, offset: 0, index: 0)
            encoder.setBuffer(plan.rowWeights, offset: 0, index: 1)
        }
    }

    /// Noise reduction: reads `input` and, when `parameters.history` is above 0, the denoiser's `previous` result, and
    /// writes the new result, which the caller keeps as the next frame's `previous`.
    func denoise(
        _ parameters: DenoiseParameters, input: any MTLTexture, previous: any MTLTexture, output: any MTLTexture,
        commands: any MTLCommandBuffer
    ) throws {
        try dispatch(commands, denoiseKernel, width: output.width, height: output.height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(previous, index: 1)
            encoder.setTexture(output, index: 2)
            Self.bind(encoder, parameters, index: 0)
        }
    }

    /// Thins the edges of a scaled picture, for flat-colour drawn art.
    func lineArt(_ parameters: LineArtParameters, input: any MTLTexture, output: any MTLTexture, commands: any MTLCommandBuffer) throws {
        try dispatch(commands, lineArtKernel, width: output.width, height: output.height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Self.bind(encoder, parameters, index: 0)
        }
    }

    /// Deband, sharpen, vivid and a touch of dither in one pass; with every stage off it is an exact copy.
    func compose(_ parameters: ComposeParameters, input: any MTLTexture, output: any MTLTexture, commands: any MTLCommandBuffer) throws {
        try dispatch(commands, composeKernel, width: output.width, height: output.height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Self.bind(encoder, parameters, index: 0)
        }
    }

    private func dispatch(
        _ commands: any MTLCommandBuffer, _ kernel: any MTLComputePipelineState, width: Int, height: Int,
        bind: (any MTLComputeCommandEncoder) -> Void
    ) throws {
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EnhanceFailure("Metal gave no compute encoder") }
        encoder.setComputePipelineState(kernel)
        bind(encoder)
        let across = kernel.threadExecutionWidth
        let down = max(kernel.maxTotalThreadsPerThreadgroup / across, 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: across, height: down, depth: 1)
        )
        encoder.endEncoding()
    }

    private func buffer<T>(_ values: [T]) -> (any MTLBuffer)? {
        values.withUnsafeBytes { raw -> (any MTLBuffer)? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
    }

    private static func bind<T>(_ encoder: any MTLComputeCommandEncoder, _ value: T, index: Int) {
        var copy = value
        encoder.setBytes(&copy, length: MemoryLayout<T>.stride, index: index)
    }
}

/// The denoiser's memory of the last frame: two half-float textures used in turns, one holding the newest result and one
/// for the next, and the record of when that result may be trusted. Made once for a size and a scaler, never per frame.
final class DenoiseHistory: @unchecked Sendable {
    let size: PixelSize
    let kind: EnhanceUpscalerKind?
    private let textures: [any MTLTexture]
    private var newest = 0
    private var memory = DenoiseMemory()

    init?(gpu: EnhanceGPU, size: PixelSize, kind: EnhanceUpscalerKind?) {
        guard let first = gpu.makeTexture(size, format: .rgba16Float), let second = gpu.makeTexture(size, format: .rgba16Float)
        else { return nil }
        self.size = size
        self.kind = kind
        textures = [first, second]
    }

    func matches(size: PixelSize, kind: EnhanceUpscalerKind?) -> Bool {
        self.size == size && self.kind == kind
    }

    /// What the next frame reads and writes: the previous result, the texture for the new one, and whether the previous
    /// result may be used (`epoch` and `time` say where the frame is in the video).
    func next(epoch: Int, time: Double?) -> (previous: any MTLTexture, output: any MTLTexture, remembers: Bool) {
        (textures[newest], textures[1 - newest], memory.remembers(epoch: epoch, time: time))
    }

    /// The frame has been encoded: its result is now the newest.
    func commit(epoch: Int, time: Double?) {
        newest = 1 - newest
        memory.record(epoch: epoch, time: time)
    }
}
