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
}

/// The line-art kernel's parameter block, laid out as the shader declares it.
struct LineArtParameters {
    var strength: Float
}

/// The taps and the one intermediate texture of a Lanczos scale from one size to another.
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

    /// Video-range or full-range NV12 into BGRA at the same size, using the video's own matrix.
    func ingest(
        _ coefficients: IngestCoefficients, luma: any MTLTexture, chroma: any MTLTexture, output: any MTLTexture,
        commands: any MTLCommandBuffer
    ) throws {
        try dispatch(commands, ingestKernel, width: output.width, height: output.height) { encoder in
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(output, index: 2)
            Self.bind(encoder, coefficients, index: 0)
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

    /// Thins the edges of a scaled picture, for flat-colour drawn art.
    func lineArt(_ parameters: LineArtParameters, input: any MTLTexture, output: any MTLTexture, commands: any MTLCommandBuffer) throws {
        try dispatch(commands, lineArtKernel, width: output.width, height: output.height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Self.bind(encoder, parameters, index: 0)
        }
    }

    /// Deband, sharpen and a touch of dither in one pass; with both off it is an exact copy.
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
