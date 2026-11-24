import Foundation
import Metal
import Testing
@testable import VideoEngine

private func hasMetal() -> Bool { MTLCreateSystemDefaultDevice() != nil }

private let needsMetal: Comment = "needs a Metal device; a simulator without one skips these, and the device sheet (ENGINE.md, E1-E8) covers the kernels then"

/// Whether an 8-bit channel is within `tolerance` levels of the value it should have.
private func isNear(_ got: UInt8, _ wanted: Int, within tolerance: Int) -> Bool {
    let difference = Int(got) - wanted
    return difference <= tolerance && difference >= -tolerance
}

/// A value in 0...1 as the 8-bit level it is stored as.
private func eightBitLevel(_ value: Float) -> Int {
    let clamped = min(max(value, 0), 1)
    return Int((clamped * 255).rounded())
}

/// `pixels` BGRA pixels that are all one opaque colour.
private func flatBGRA(pixels: Int, blue: UInt8, green: UInt8, red: UInt8) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(pixels * 4)
    for _ in 0..<pixels {
        bytes.append(blue)
        bytes.append(green)
        bytes.append(red)
        bytes.append(255)
    }
    return bytes
}

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
        var chromaBytes: [UInt8] = []
        for _ in 0..<16 {
            chromaBytes.append(100)
            chromaBytes.append(160)
        }
        let chroma = try kit.texture(.rg8Unorm, 4, 4, bytes: chromaBytes)
        let output = try kit.texture(.bgra8Unorm, 8, 8)
        let coefficients = IngestCoefficients(matrix: .bt709, fullRange: false)
        let pipeline = try kit.pipeline("ingest_nv12")
        try kit.run(pipeline, width: 8, height: 8) { encoder in
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setTexture(output, index: 2)
            Kit.set(encoder, coefficients, index: 0)
        }
        let expected = coefficients.rgb(y: 120.0 / 255.0, cb: 100.0 / 255.0, cr: 160.0 / 255.0)
        let wantedRed = eightBitLevel(expected.r)
        let wantedGreen = eightBitLevel(expected.g)
        let wantedBlue = eightBitLevel(expected.b)
        let pixels = kit.bytes(of: output, bytesPerPixel: 4)
        #expect(pixels.count == 8 * 8 * 4)
        for start in stride(from: 0, to: pixels.count, by: 4) {
            #expect(isNear(pixels[start + 2], wantedRed, within: 2))
            #expect(isNear(pixels[start + 1], wantedGreen, within: 2))
            #expect(isNear(pixels[start], wantedBlue, within: 2))
            #expect(pixels[start + 3] == 255)
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func composeWithEveryStageOffCopiesThePicture() throws {
        let kit = try Kit()
        var picture: [UInt8] = []
        for index in 0..<36 {
            picture.append(UInt8(truncatingIfNeeded: index * 7))
            picture.append(UInt8(truncatingIfNeeded: index * 13))
            picture.append(UInt8(truncatingIfNeeded: index * 29))
            picture.append(255)
        }
        let input = try kit.texture(.bgra8Unorm, 6, 6, bytes: picture)
        let output = try kit.texture(.bgra8Unorm, 6, 6)
        let parameters = ComposeParameters(sharpen: 0, deband: 0, debandRadius: 8, debandThreshold: 0.02, frame: 0)
        let pipeline = try kit.pipeline("compose")
        try kit.run(pipeline, width: 6, height: 6) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, parameters, index: 0)
        }
        let result = kit.bytes(of: output, bytesPerPixel: 4)
        #expect(result.count == picture.count)
        for (got, wanted) in zip(result, picture) {
            #expect(isNear(got, Int(wanted), within: 1))
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func debandAndSharpenLeaveAFlatPictureFlat() throws {
        let kit = try Kit()
        let flat = flatBGRA(pixels: 256, blue: 200, green: 140, red: 90)
        let input = try kit.texture(.bgra8Unorm, 16, 16, bytes: flat)
        let output = try kit.texture(.bgra8Unorm, 16, 16)
        let radius = EnhanceMath.debandRadius(1, scale: 2)
        let threshold = EnhanceMath.debandThreshold(1)
        let parameters = ComposeParameters(sharpen: 1, deband: 1, debandRadius: radius, debandThreshold: threshold, frame: 3)
        let pipeline = try kit.pipeline("compose")
        try kit.run(pipeline, width: 16, height: 16) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, parameters, index: 0)
        }
        // The dither moves a value by one step at most, and rounding by another.
        let result = kit.bytes(of: output, bytesPerPixel: 4)
        #expect(result.count == flat.count)
        for (got, wanted) in zip(result, flat) {
            #expect(isNear(got, Int(wanted), within: 2))
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func lanczosKeepsAFlatPictureFlatWhenItDoublesIt() throws {
        let kit = try Kit()
        let blue: UInt8 = 200
        let green: UInt8 = 100
        let red: UInt8 = 50
        let flat = flatBGRA(pixels: 36, blue: blue, green: green, red: red)
        let input = try kit.texture(.bgra8Unorm, 6, 6, bytes: flat)
        let middle = try kit.texture(.rgba16Float, 12, 6)
        let output = try kit.texture(.bgra8Unorm, 12, 12)
        let columns = LanczosTaps(source: 6, output: 12)
        let rows = LanczosTaps(source: 6, output: 12)
        let columnStarts = try kit.buffer(columns.starts)
        let columnWeights = try kit.buffer(columns.weights)
        let rowStarts = try kit.buffer(rows.starts)
        let rowWeights = try kit.buffer(rows.weights)
        let horizontal = try kit.pipeline("lanczos_horizontal")
        let vertical = try kit.pipeline("lanczos_vertical")
        try kit.run(horizontal, width: 12, height: 6) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(middle, index: 1)
            encoder.setBuffer(columnStarts, offset: 0, index: 0)
            encoder.setBuffer(columnWeights, offset: 0, index: 1)
        }
        try kit.run(vertical, width: 12, height: 12) { encoder in
            encoder.setTexture(middle, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBuffer(rowStarts, offset: 0, index: 0)
            encoder.setBuffer(rowWeights, offset: 0, index: 1)
        }
        let pixels = kit.bytes(of: output, bytesPerPixel: 4)
        #expect(pixels.count == 12 * 12 * 4)
        for start in stride(from: 0, to: pixels.count, by: 4) {
            #expect(isNear(pixels[start], Int(blue), within: 1))
            #expect(isNear(pixels[start + 1], Int(green), within: 1))
            #expect(isNear(pixels[start + 2], Int(red), within: 1))
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func lineArtLeavesAFlatPictureAlone() throws {
        let kit = try Kit()
        let flat = flatBGRA(pixels: 64, blue: 60, green: 120, red: 180)
        let input = try kit.texture(.bgra8Unorm, 8, 8, bytes: flat)
        let output = try kit.texture(.bgra8Unorm, 8, 8)
        let parameters = LineArtParameters(strength: 0.75)
        let pipeline = try kit.pipeline("line_art_steepen")
        try kit.run(pipeline, width: 8, height: 8) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, parameters, index: 0)
        }
        let result = kit.bytes(of: output, bytesPerPixel: 4)
        #expect(result.count == flat.count)
        for (got, wanted) in zip(result, flat) {
            #expect(isNear(got, Int(wanted), within: 1))
        }
    }
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
            let rowBytes = bytes.count / height
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: rowBytes)
        }
        return texture
    }

    func buffer<T>(_ values: [T]) throws -> any MTLBuffer {
        let made = values.withUnsafeBytes { raw -> (any MTLBuffer)? in
            guard let base = raw.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
        guard let buffer = made else { throw Failure(description: "no buffer") }
        return buffer
    }

    func bytes(of texture: any MTLTexture, bytesPerPixel: Int) -> [UInt8] {
        let rowBytes = texture.width * bytesPerPixel
        var result = [UInt8](repeating: 0, count: rowBytes * texture.height)
        let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
        texture.getBytes(&result, bytesPerRow: rowBytes, from: region, mipmapLevel: 0)
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
        let grid = MTLSize(width: width, height: height, depth: 1)
        let group = MTLSize(width: across, height: down, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw error }
    }
}
