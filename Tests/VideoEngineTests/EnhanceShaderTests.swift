import Foundation
import Metal
import Testing
@testable import VideoEngine

private func hasMetal() -> Bool { MTLCreateSystemDefaultDevice() != nil }

private let needsMetal: Comment = "needs a Metal device; a simulator without one skips these, and the device sheet (ENGINE.md, E1-E8) covers the kernels then"

/// The enhancer's kernels on tiny textures: that the Metal compiler accepts the source, and that each kernel does the
/// plain thing it promises on pictures whose right answer is known. Speed, memory and Apple's own scalers need a phone.
struct EnhanceShaderTests {
    @Test(.enabled(if: hasMetal(), needsMetal))
    func everyKernelCompiles() throws {
        let kit = try Kit()
        for name in ["ingest_nv12", "lanczos_horizontal", "lanczos_vertical", "line_art_steepen", "compose"] {
            let pipeline = try kit.pipeline(name)
            #expect(pipeline.maxTotalThreadsPerThreadgroup > 0, "\(name)")
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func ingestMatchesTheCPUArithmetic() throws {
        let kit = try Kit()
        let luma = try kit.texture(.r8Unorm, 8, 8, bytes: [UInt8](repeating: 120, count: 64))
        let chromaBytes: [UInt8] = (0..<16).flatMap { _ -> [UInt8] in [100, 160] }
        let chroma = try kit.texture(.rg8Unorm, 4, 4, bytes: chromaBytes)
        let output = try kit.texture(.bgra8Unorm, 8, 8)
        let coefficients = IngestCoefficients(matrix: .bt709, fullRange: false)
        try kit.run(kit.pipeline("ingest_nv12"), width: 8, height: 8) { encoder in
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(output, index: 2)
            Kit.set(encoder, coefficients, index: 0)
        }
        let expected = coefficients.rgb(y: 120 / 255, cb: 100 / 255, cr: 160 / 255)
        let pixels = kit.bytes(of: output, bytesPerPixel: 4)
        for start in stride(from: 0, to: pixels.count, by: 4) {
            #expect(abs(Int(pixels[start + 2]) - Self.level(expected.r)) <= 2)
            #expect(abs(Int(pixels[start + 1]) - Self.level(expected.g)) <= 2)
            #expect(abs(Int(pixels[start]) - Self.level(expected.b)) <= 2)
            #expect(pixels[start + 3] == 255)
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func composeWithEveryStageOffCopiesThePicture() throws {
        let kit = try Kit()
        let picture: [UInt8] = (0..<36).flatMap { index -> [UInt8] in
            [UInt8((index * 7) % 256), UInt8((index * 13) % 256), UInt8((index * 29) % 256), 255]
        }
        let input = try kit.texture(.bgra8Unorm, 6, 6, bytes: picture)
        let output = try kit.texture(.bgra8Unorm, 6, 6)
        let parameters = ComposeParameters(sharpen: 0, deband: 0, debandRadius: 8, debandThreshold: 0.02, frame: 0)
        try kit.run(kit.pipeline("compose"), width: 6, height: 6) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, parameters, index: 0)
        }
        let result = kit.bytes(of: output, bytesPerPixel: 4)
        #expect(result.count == picture.count)
        for (got, wanted) in zip(result, picture) {
            #expect(abs(Int(got) - Int(wanted)) <= 1)
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func debandAndSharpenLeaveAFlatPictureFlat() throws {
        let kit = try Kit()
        let flat: [UInt8] = (0..<256).flatMap { _ -> [UInt8] in [200, 140, 90, 255] }
        let input = try kit.texture(.bgra8Unorm, 16, 16, bytes: flat)
        let output = try kit.texture(.bgra8Unorm, 16, 16)
        let parameters = ComposeParameters(
            sharpen: 1, deband: 1, debandRadius: EnhanceMath.debandRadius(1, scale: 2),
            debandThreshold: EnhanceMath.debandThreshold(1), frame: 3
        )
        try kit.run(kit.pipeline("compose"), width: 16, height: 16) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, parameters, index: 0)
        }
        // The dither moves a value by one step at most, and rounding by another.
        for (got, wanted) in zip(kit.bytes(of: output, bytesPerPixel: 4), flat) {
            #expect(abs(Int(got) - Int(wanted)) <= 2)
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func lanczosKeepsAFlatPictureFlatWhenItDoublesIt() throws {
        let kit = try Kit()
        let flat: [UInt8] = (0..<36).flatMap { _ -> [UInt8] in [200, 100, 50, 255] }
        let input = try kit.texture(.bgra8Unorm, 6, 6, bytes: flat)
        let middle = try kit.texture(.rgba16Float, 12, 6)
        let output = try kit.texture(.bgra8Unorm, 12, 12)
        let columns = LanczosTaps(source: 6, output: 12)
        let rows = LanczosTaps(source: 6, output: 12)
        let columnStarts = try kit.buffer(columns.starts), columnWeights = try kit.buffer(columns.weights)
        let rowStarts = try kit.buffer(rows.starts), rowWeights = try kit.buffer(rows.weights)
        try kit.run(kit.pipeline("lanczos_horizontal"), width: 12, height: 6) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(middle, index: 1)
            encoder.setBuffer(columnStarts, offset: 0, index: 0)
            encoder.setBuffer(columnWeights, offset: 0, index: 1)
        }
        try kit.run(kit.pipeline("lanczos_vertical"), width: 12, height: 12) { encoder in
            encoder.setTexture(middle, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBuffer(rowStarts, offset: 0, index: 0)
            encoder.setBuffer(rowWeights, offset: 0, index: 1)
        }
        let pixels = kit.bytes(of: output, bytesPerPixel: 4)
        #expect(pixels.count == 12 * 12 * 4)
        for start in stride(from: 0, to: pixels.count, by: 4) {
            #expect(abs(Int(pixels[start]) - 50) <= 1)
            #expect(abs(Int(pixels[start + 1]) - 100) <= 1)
            #expect(abs(Int(pixels[start + 2]) - 200) <= 1)
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func lineArtLeavesAFlatPictureAlone() throws {
        let kit = try Kit()
        let flat: [UInt8] = (0..<64).flatMap { _ -> [UInt8] in [60, 120, 180, 255] }
        let input = try kit.texture(.bgra8Unorm, 8, 8, bytes: flat)
        let output = try kit.texture(.bgra8Unorm, 8, 8)
        try kit.run(kit.pipeline("line_art_steepen"), width: 8, height: 8) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, LineArtParameters(strength: 0.75), index: 0)
        }
        for (got, wanted) in zip(kit.bytes(of: output, bytesPerPixel: 4), flat) {
            #expect(abs(Int(got) - Int(wanted)) <= 1)
        }
    }

    /// A value in 0...1 as the 8-bit level it is stored as.
    private static func level(_ value: Float) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }
}

// The kernels' parameter structs as the shader declares them.
private struct ComposeParameters {
    var sharpen: Float
    var deband: Float
    var debandRadius: Float
    var debandThreshold: Float
    var frame: UInt32
}

private struct LineArtParameters {
    var strength: Float
}

/// A Metal device with the enhancer's kernels compiled, and the few helpers the tests share.
private struct Kit {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let library: any MTLLibrary

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure(description: "no Metal device")
        }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        self.device = device
        self.queue = queue
        self.library = try device.makeLibrary(source: EnhanceShaders.source, options: options)
    }

    func pipeline(_ name: String) throws -> any MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else { throw Failure(description: "no kernel named \(name)") }
        return try device.makeComputePipelineState(function: function)
    }

    func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, bytes: [UInt8]? = nil) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure(description: "no texture") }
        if let bytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytes.count / height)
        }
        return texture
    }

    func buffer<T>(_ values: [T]) throws -> any MTLBuffer {
        guard let buffer = device.makeBuffer(bytes: values, length: values.count * MemoryLayout<T>.stride, options: .storageModeShared) else {
            throw Failure(description: "no buffer")
        }
        return buffer
    }

    func bytes(of texture: any MTLTexture, bytesPerPixel: Int) -> [UInt8] {
        let rowBytes = texture.width * bytesPerPixel
        var result = [UInt8](repeating: 0, count: rowBytes * texture.height)
        texture.getBytes(&result, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return result
    }

    static func set<T>(_ encoder: any MTLComputeCommandEncoder, _ value: T, index: Int) {
        var copy = value
        encoder.setBytes(&copy, length: MemoryLayout<T>.stride, index: index)
    }

    /// Runs `pipeline` over `width` by `height` threads with the arguments `bind` sets, and waits for the GPU.
    func run(_ pipeline: any MTLComputePipelineState, width: Int, height: Int, bind: (any MTLComputeCommandEncoder) -> Void) throws {
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw Failure(description: "no command buffer")
        }
        encoder.setComputePipelineState(pipeline)
        bind(encoder)
        let across = pipeline.threadExecutionWidth
        let down = max(pipeline.maxTotalThreadsPerThreadgroup / across, 1)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: across, height: down, depth: 1)
        )
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }
}
