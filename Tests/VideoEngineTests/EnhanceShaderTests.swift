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
        for name in [
            "ingest_nv12", "reorient_luma", "reorient_chroma", "lanczos_horizontal", "lanczos_vertical", "line_art_steepen", "compose",
            "denoise", "downscale_horizontal", "downscale_vertical",
        ] {
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
            Kit.set(encoder, IngestGeometry.identity, index: 1)
            Kit.set(encoder, DeblockParameters.off, index: 2)
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

    /// A coded 12x8 frame whose every luma sample is different, and a 6x4 chroma plane whose every sample is different.
    private static func patternedFrame() -> (luma: [UInt8], chroma: [UInt8]) {
        var luma: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<12 { luma.append(UInt8(10 + y * 12 + x)) }
        }
        var chroma: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<6 {
                chroma.append(UInt8(20 + x * 7 + y * 3))
                chroma.append(UInt8(200 - x * 5 - y * 11))
            }
        }
        return (luma, chroma)
    }

    /// Every way a frame can be turned: with or without the axis swap and each flip.
    private static var everyOrientation: [PictureOrientation] {
        var all: [PictureOrientation] = []
        for swap in [false, true] {
            for across in [false, true] {
                for down in [false, true] { all.append(PictureOrientation(swapsAxes: swap, flipsAcross: across, flipsDown: down)) }
            }
        }
        return all
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func reorientKernelsCropAndTurnLikeTheGeometry() throws {
        let kit = try Kit()
        let frame = Self.patternedFrame()
        let luma = try kit.texture(.r8Unorm, 12, 8, bytes: frame.luma)
        let chroma = try kit.texture(.rg8Unorm, 6, 4, bytes: frame.chroma)
        let lumaPipeline = try kit.pipeline("reorient_luma")
        let chromaPipeline = try kit.pipeline("reorient_chroma")
        for orientation in Self.everyOrientation {
            let geometry = try #require(PictureGeometry.make(
                coded: PixelSize(width: 12, height: 8), clean: CGRect(x: 2, y: 2, width: 6, height: 4), pixelAspect: 1,
                orientation: orientation
            ))
            let size = geometry.size
            let outLuma = try kit.texture(.r8Unorm, size.width, size.height)
            let outChroma = try kit.texture(.rg8Unorm, size.width / 2, size.height / 2)
            let block = IngestGeometry(geometry)
            try kit.run(lumaPipeline, width: size.width, height: size.height) { encoder in
                encoder.setTexture(luma, index: 0)
                encoder.setTexture(outLuma, index: 1)
                Kit.set(encoder, block, index: 0)
                Kit.set(encoder, DeblockParameters.off, index: 1)
            }
            try kit.run(chromaPipeline, width: size.width / 2, height: size.height / 2) { encoder in
                encoder.setTexture(chroma, index: 0)
                encoder.setTexture(outChroma, index: 1)
                Kit.set(encoder, block, index: 0)
            }
            let lumaOut = kit.bytes(of: outLuma, bytesPerPixel: 1)
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let coded = geometry.codedPixel(x: x, y: y)
                    #expect(lumaOut[y * size.width + x] == UInt8(10 + coded.y * 12 + coded.x), "\(orientation) luma \(x),\(y)")
                }
            }
            let chromaOut = kit.bytes(of: outChroma, bytesPerPixel: 2)
            for y in 0..<(size.height / 2) {
                for x in 0..<(size.width / 2) {
                    let coded = geometry.codedPixel(x: x * 2, y: y * 2)
                    let sx = coded.x >> 1
                    let sy = coded.y >> 1
                    let start = (y * (size.width / 2) + x) * 2
                    #expect(chromaOut[start] == UInt8(20 + sx * 7 + sy * 3), "\(orientation) cb \(x),\(y)")
                    #expect(chromaOut[start + 1] == UInt8(200 - sx * 5 - sy * 11), "\(orientation) cr \(x),\(y)")
                }
            }
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func ingestCropsAndTurnsLikeTheGeometry() throws {
        let kit = try Kit()
        let frame = Self.patternedFrame()
        let luma = try kit.texture(.r8Unorm, 12, 8, bytes: frame.luma)
        var neutral: [UInt8] = []
        for _ in 0..<24 {
            neutral.append(128)
            neutral.append(128)
        }
        let chroma = try kit.texture(.rg8Unorm, 6, 4, bytes: neutral)
        let coefficients = IngestCoefficients(matrix: .bt709, fullRange: false)
        let pipeline = try kit.pipeline("ingest_nv12")
        for orientation in Self.everyOrientation {
            let geometry = try #require(PictureGeometry.make(
                coded: PixelSize(width: 12, height: 8), clean: CGRect(x: 2, y: 2, width: 6, height: 4), pixelAspect: 1,
                orientation: orientation
            ))
            let size = geometry.size
            let output = try kit.texture(.bgra8Unorm, size.width, size.height)
            let block = IngestGeometry(geometry)
            try kit.run(pipeline, width: size.width, height: size.height) { encoder in
                encoder.setTexture(luma, index: 0)
                encoder.setTexture(chroma, index: 1)
                encoder.setTexture(output, index: 2)
                Kit.set(encoder, coefficients, index: 0)
                Kit.set(encoder, block, index: 1)
                Kit.set(encoder, DeblockParameters.off, index: 2)
            }
            let pixels = kit.bytes(of: output, bytesPerPixel: 4)
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let coded = geometry.codedPixel(x: x, y: y)
                    let sample = Float(10 + coded.y * 12 + coded.x) / 255
                    let wanted = eightBitLevel(coefficients.rgb(y: sample, cb: 128.0 / 255.0, cr: 128.0 / 255.0).g)
                    let start = (y * size.width + x) * 4
                    #expect(isNear(pixels[start + 1], wanted, within: 2), "\(orientation) \(x),\(y)")
                }
            }
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
        let parameters = ComposeParameters(sharpen: 1, deband: 1, debandRadius: radius, debandThreshold: threshold, frame: 3,
            dither: EnhanceMath.ditherCodes(deband: 1, denoise: 0, vivid: 0)
        )
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

/// The v3.1.0 kernels on tiny pictures: block-edge softening, noise reduction, vivid and the downscale, each against a
/// picture whose right answer is known. Whether they look right on real video is for the device sheet (ENGINE.md, E11-E15).
struct EnhanceEffectsShaderTests {
    /// Deterministic noise, the same on every run.
    private struct Noise {
        var state: UInt64

        mutating func next(amplitude: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(2 * amplitude + 1)) - amplitude
        }
    }

    /// A BGRA picture of one colour per column (`columns`) with noise of `amplitude` codes on every channel.
    private static func noisyFrame(
        width: Int, height: Int, amplitude: Int, noise: inout Noise, level: (Int) -> Int
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for _ in 0..<height {
            for x in 0..<width {
                for _ in 0..<3 { bytes.append(UInt8(max(0, min(255, level(x) + noise.next(amplitude: amplitude))))) }
                bytes.append(255)
            }
        }
        return bytes
    }

    private static func floats(of texture: any MTLTexture, kit: Kit) -> [Float] {
        var result = [Float](repeating: 0, count: texture.width * texture.height * 4)
        let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
        texture.getBytes(&result, bytesPerRow: texture.width * 16, from: region, mipmapLevel: 0)
        return result
    }

    /// The green channel in codes of 255 for every pixel at least `margin` from the edge, from BGRA bytes.
    private static func greens(_ bytes: [UInt8], width: Int, height: Int, margin: Int = 2) -> [Double] {
        var values: [Double] = []
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) { values.append(Double(bytes[(y * width + x) * 4 + 1])) }
        }
        return values
    }

    private static func greens(_ pixels: [Float], width: Int, height: Int, margin: Int = 2) -> [Double] {
        var values: [Double] = []
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) { values.append(Double(pixels[(y * width + x) * 4 + 1]) * 255) }
        }
        return values
    }

    private static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }

    private static func variance(_ values: [Double]) -> Double {
        let centre = mean(values)
        return values.reduce(0) { $0 + ($1 - centre) * ($1 - centre) } / Double(max(values.count, 1))
    }

    /// The mean of the green channel down one column, in codes.
    private static func columnMean(_ pixels: [Float], width: Int, height: Int, column: Int) -> Double {
        mean((0..<height).map { Double(pixels[($0 * width + column) * 4 + 1]) * 255 })
    }

    // MARK: Deblock

    /// `luma` (one byte a pixel) through the luma kernel with the deblock at `strength`, at the same size.
    private func deblocked(_ luma: [UInt8], width: Int, height: Int, strength: Double) throws -> [UInt8] {
        let kit = try Kit()
        let input = try kit.texture(.r8Unorm, width, height, bytes: luma)
        let output = try kit.texture(.r8Unorm, width, height)
        let pipeline = try kit.pipeline("reorient_luma")
        let parameters = DeblockParameters(strength: strength)
        try kit.run(pipeline, width: width, height: height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, IngestGeometry.identity, index: 0)
            Kit.set(encoder, parameters, index: 1)
        }
        return kit.bytes(of: output, bytesPerPixel: 1)
    }

    /// A picture of `width` by `height` whose value is `low` before the block edge at 8 and `high` from it, across or down.
    private static func stepped(width: Int, height: Int, low: UInt8, high: UInt8, acrossTheRow: Bool) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width { bytes.append((acrossTheRow ? x : y) < 8 ? low : high) }
        }
        return bytes
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func deblockSoftensASmallStepAcrossABlockEdgeInBothDirections() throws {
        for acrossTheRow in [true, false] {
            let width = acrossTheRow ? 24 : 16
            let height = acrossTheRow ? 16 : 24
            let source = Self.stepped(width: width, height: height, low: 100, high: 106, acrossTheRow: acrossTheRow)
            let result = try deblocked(source, width: width, height: height, strength: 1)
            func line(_ index: Int) -> Int { Int(acrossTheRow ? result[8 * width + index] : result[index * width + 8]) }
            #expect(abs(line(7) - line(8)) <= 1, "the step of 6 codes should be about gone")
            #expect(isNear(UInt8(line(8)), 103, within: 1))
            for index in 3..<11 { #expect(line(index) <= line(index + 1) + 1, "a ramp, not a bump, at \(index)") }
            // Away from the edge nothing moves.
            for index in [0, 1, 2, 3, 12, 13, 20, 23] where index < (acrossTheRow ? width : height) {
                let wanted = index < 8 ? 100 : 106
                #expect(isNear(UInt8(line(index)), wanted, within: 1), "\(index)")
            }
        }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func deblockKeepsASharpEdgeAndBusyTexture() throws {
        let sharp = Self.stepped(width: 24, height: 16, low: 60, high: 180, acrossTheRow: true)
        let sharpResult = try deblocked(sharp, width: 24, height: 16, strength: 1)
        for (got, wanted) in zip(sharpResult, sharp) { #expect(isNear(got, Int(wanted), within: 1)) }

        var busy: [UInt8] = []
        for _ in 0..<16 {
            for x in 0..<24 { busy.append(UInt8((x % 2 == 0 ? 90 : 110) + (x >= 8 ? 6 : 0))) }
        }
        let busyResult = try deblocked(busy, width: 24, height: 16, strength: 1)
        for (got, wanted) in zip(busyResult, busy) { #expect(isNear(got, Int(wanted), within: 1)) }
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func deblockOffIsAnExactCopy() throws {
        let source = Self.stepped(width: 24, height: 16, low: 100, high: 106, acrossTheRow: true)
        let result = try deblocked(source, width: 24, height: 16, strength: 0)
        #expect(result == source)
    }

    // MARK: Denoise

    private static let denoiseSize = (width: 32, height: 16)

    /// Runs `frames` in turn through the denoise kernel with the history in two ping-pong textures; `strength` and
    /// `remembering` (which frame indexes may use the previous result) say how. Returns every frame's output.
    private func denoised(_ frames: [[UInt8]], strength: Double, remembering: (Int) -> Bool) throws -> [[Float]] {
        let (width, height) = Self.denoiseSize
        let kit = try Kit()
        let pipeline = try kit.pipeline("denoise")
        let history = [try kit.texture(.rgba32Float, width, height), try kit.texture(.rgba32Float, width, height)]
        var results: [[Float]] = []
        for (index, bytes) in frames.enumerated() {
            let input = try kit.texture(.bgra8Unorm, width, height, bytes: bytes)
            let previous = history[index % 2]
            let output = history[(index + 1) % 2]
            let parameters = DenoiseParameters(strength: strength, remembers: remembering(index))
            try kit.run(pipeline, width: width, height: height) { encoder in
                encoder.setTexture(input, index: 0)
                encoder.setTexture(previous, index: 1)
                encoder.setTexture(output, index: 2)
                Kit.set(encoder, parameters, index: 0)
            }
            results.append(Self.floats(of: output, kit: kit))
        }
        return results
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func theSpatialStepAloneCutsTheNoiseOfASingleFrame() throws {
        let (width, height) = Self.denoiseSize
        var noise = Noise(state: 7)
        let frame = Self.noisyFrame(width: width, height: height, amplitude: 6, noise: &noise) { _ in 128 }
        let result = try denoised([frame], strength: 1, remembering: { _ in false })[0]
        let before = Self.variance(Self.greens(frame, width: width, height: height))
        let after = Self.variance(Self.greens(result, width: width, height: height))
        #expect(before > 5, "the test picture should be noisy")
        #expect(after < 0.5 * before, "variance \(before) -> \(after)")
        #expect(abs(Self.mean(Self.greens(result, width: width, height: height)) - 128) < 1.5)
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func theTemporalStepCutsTheNoiseOfAStillPictureFurther() throws {
        let (width, height) = Self.denoiseSize
        var noise = Noise(state: 11)
        let frames = (0..<8).map { _ in Self.noisyFrame(width: width, height: height, amplitude: 6, noise: &noise) { _ in 128 } }
        let results = try denoised(frames, strength: 0.5, remembering: { $0 > 0 })
        let before = Self.variance(Self.greens(frames[7], width: width, height: height))
        let spatialOnly = try denoised([frames[7]], strength: 0.5, remembering: { _ in false })[0]
        let spatial = Self.variance(Self.greens(spatialOnly, width: width, height: height))
        let after = Self.variance(Self.greens(results[7], width: width, height: height))
        #expect(after < 0.3 * before, "variance \(before) -> \(after)")
        #expect(after < 0.7 * spatial, "the history should add to the spatial step: \(spatial) -> \(after)")
        #expect(abs(Self.mean(Self.greens(results[7], width: width, height: height)) - 128) < 1.5)
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func aStaticEdgeStaysSharpWhileTheNoiseGoes() throws {
        let (width, height) = Self.denoiseSize
        var noise = Noise(state: 23)
        let frames = (0..<6).map { _ in
            Self.noisyFrame(width: width, height: height, amplitude: 4, noise: &noise) { $0 < 16 ? 60 : 200 }
        }
        let last = try #require(try denoised(frames, strength: 0.5, remembering: { $0 > 0 }).last)
        for column in 2...13 { #expect(abs(Self.columnMean(last, width: width, height: height, column: column) - 60) < 1.5, "\(column)") }
        for column in 18...29 { #expect(abs(Self.columnMean(last, width: width, height: height, column: column) - 200) < 1.5, "\(column)") }
        #expect(abs(Self.columnMean(last, width: width, height: height, column: 15) - 60) < 2, "the last dark column")
        #expect(abs(Self.columnMean(last, width: width, height: height, column: 16) - 200) < 2, "the first bright column")
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func aSceneChangeLeavesNoGhostOfTheOldPicture() throws {
        let (width, height) = Self.denoiseSize
        var noise = Noise(state: 31)
        var frames = (0..<5).map { _ in Self.noisyFrame(width: width, height: height, amplitude: 4, noise: &noise) { _ in 40 } }
        frames.append(Self.noisyFrame(width: width, height: height, amplitude: 4, noise: &noise) { _ in 200 })
        let results = try denoised(frames, strength: 1, remembering: { $0 > 0 })
        let dark = Self.greens(results[4], width: width, height: height)
        #expect(abs(Self.mean(dark) - 40) < 2)
        let cut = Self.greens(results[5], width: width, height: height)
        #expect((cut.min() ?? 0) > 190, "the first frame of the new scene should be the new scene, not a blend")
        #expect(abs(Self.mean(cut) - 200) < 2)
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func withNoHistoryThePreviousTextureIsNotRead() throws {
        let (width, height) = Self.denoiseSize
        let kit = try Kit()
        let input = try kit.texture(.bgra8Unorm, width, height, bytes: flatBGRA(pixels: width * height, blue: 100, green: 100, red: 100))
        let bright = try kit.texture(.rgba32Float, width, height, bytes: [UInt8](repeating: 0x3F, count: width * height * 16))
        let output = try kit.texture(.rgba32Float, width, height)
        let pipeline = try kit.pipeline("denoise")
        let parameters = DenoiseParameters(strength: 1, remembers: false)
        try kit.run(pipeline, width: width, height: height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(bright, index: 1)
            encoder.setTexture(output, index: 2)
            Kit.set(encoder, parameters, index: 0)
        }
        let result = Self.greens(Self.floats(of: output, kit: kit), width: width, height: height)
        #expect(abs(Self.mean(result) - 100) < 0.5)
    }

    // MARK: Downscale

    private func downscaled(_ bytes: [UInt8], from source: PixelSize, to target: PixelSize) throws -> [UInt8] {
        let kit = try Kit()
        let input = try kit.texture(.bgra8Unorm, source.width, source.height, bytes: bytes)
        let middle = try kit.texture(.rgba16Float, target.width, source.height)
        let output = try kit.texture(.bgra8Unorm, target.width, target.height)
        let columns = DownscaleTaps(source: source.width, output: target.width)
        let rows = DownscaleTaps(source: source.height, output: target.height)
        let columnStarts = try kit.buffer(columns.starts)
        let columnWeights = try kit.buffer(columns.weights)
        let rowStarts = try kit.buffer(rows.starts)
        let rowWeights = try kit.buffer(rows.weights)
        try kit.run(try kit.pipeline("downscale_horizontal"), width: target.width, height: source.height) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(middle, index: 1)
            encoder.setBuffer(columnStarts, offset: 0, index: 0)
            encoder.setBuffer(columnWeights, offset: 0, index: 1)
        }
        try kit.run(try kit.pipeline("downscale_vertical"), width: target.width, height: target.height) { encoder in
            encoder.setTexture(middle, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBuffer(rowStarts, offset: 0, index: 0)
            encoder.setBuffer(rowWeights, offset: 0, index: 1)
        }
        return kit.bytes(of: output, bytesPerPixel: 4)
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func downscalingKeepsAFlatPictureFlatAndAStepInPlace() throws {
        let source = PixelSize(width: 32, height: 24)
        let target = PixelSize(width: 20, height: 15)
        let flat = flatBGRA(pixels: source.pixels, blue: 50, green: 140, red: 220)
        let flatResult = try downscaled(flat, from: source, to: target)
        #expect(flatResult.count == target.pixels * 4)
        for start in stride(from: 0, to: flatResult.count, by: 4) {
            #expect(isNear(flatResult[start], 50, within: 1))
            #expect(isNear(flatResult[start + 1], 140, within: 1))
            #expect(isNear(flatResult[start + 2], 220, within: 1))
        }
        var step: [UInt8] = []
        for _ in 0..<source.height {
            for x in 0..<source.width { step.append(contentsOf: [UInt8](repeating: x < 16 ? 20 : 230, count: 3) + [255]) }
        }
        let stepResult = try downscaled(step, from: source, to: target)
        func green(_ x: Int) -> Int { Int(stepResult[(7 * target.width + x) * 4 + 1]) }
        #expect(green(0) <= 22 && green(19) >= 228, "the ends keep their levels")
        #expect(green(5) < 60 && green(14) > 190, "the sides of the step stay on their own levels")
    }

    // MARK: Vivid

    /// The middle pixel of a 16x16 picture of one colour through the compose kernel at vivid `strength`, as (b, g, r).
    private func vivid(_ colour: (b: UInt8, g: UInt8, r: UInt8), strength: Float) throws -> (b: Int, g: Int, r: Int) {
        let kit = try Kit()
        let input = try kit.texture(.bgra8Unorm, 16, 16, bytes: flatBGRA(pixels: 256, blue: colour.b, green: colour.g, red: colour.r))
        let output = try kit.texture(.bgra8Unorm, 16, 16)
        let parameters = ComposeParameters(
            sharpen: 0, deband: 0, debandRadius: 8, debandThreshold: 0.02, frame: 0, vivid: strength, vividRadius: 4, dither: 0
        )
        try kit.run(try kit.pipeline("compose"), width: 16, height: 16) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, parameters, index: 0)
        }
        let bytes = kit.bytes(of: output, bytesPerPixel: 4)
        let middle = (8 * 16 + 8) * 4
        return (Int(bytes[middle]), Int(bytes[middle + 1]), Int(bytes[middle + 2]))
    }

    private func span(_ colour: (b: Int, g: Int, r: Int)) -> Double {
        Double(max(colour.b, colour.g, colour.r) - min(colour.b, colour.g, colour.r))
    }

    /// How much more colour (max minus min) the boosted colour has than the original, as a fraction.
    private func gain(_ colour: (b: UInt8, g: UInt8, r: UInt8), strength: Float) throws -> Double {
        let before = span((Int(colour.b), Int(colour.g), Int(colour.r)))
        return span(try vivid(colour, strength: strength)) / before - 1
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func vividRaisesSaturationAndMoreSoAtFullStrength() throws {
        let blue: (b: UInt8, g: UInt8, r: UInt8) = (170, 120, 90)
        let half = try gain(blue, strength: 0.5)
        let full = try gain(blue, strength: 1)
        #expect(half > 0.08, "half strength should be clearly visible: \(half)")
        #expect(full > half + 0.05)
        #expect(full < 0.6, "full strength is strong, not garish: \(full)")
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func vividLeavesGreyAndNearWhiteAlone() throws {
        for level in [UInt8(128), UInt8(60)] {
            let grey = try vivid((level, level, level), strength: 1)
            #expect(isNear(UInt8(grey.b), Int(level), within: 1) && isNear(UInt8(grey.g), Int(level), within: 1)
                && isNear(UInt8(grey.r), Int(level), within: 1), "grey \(level)")
        }
        let white = try vivid((246, 248, 250), strength: 1)
        #expect(isNear(UInt8(white.b), 246, within: 2) && isNear(UInt8(white.g), 248, within: 2) && isNear(UInt8(white.r), 250, within: 2))
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func vividHoldsBackOnSkinTones() throws {
        let blue = try gain((170, 120, 90), strength: 1)
        let skin = try gain((120, 150, 205), strength: 1)
        #expect(skin >= -0.01)
        #expect(skin < 0.5 * blue, "skin \(skin) against blue \(blue)")
    }

    @Test(.enabled(if: hasMetal(), needsMetal))
    func vividAddsLocalContrastAtAnEdgeAndNothingInFlatAreas() throws {
        let kit = try Kit()
        var bytes: [UInt8] = []
        for _ in 0..<8 {
            for x in 0..<24 { bytes.append(contentsOf: [UInt8](repeating: x < 12 ? 100 : 140, count: 3) + [255]) }
        }
        let input = try kit.texture(.bgra8Unorm, 24, 8, bytes: bytes)
        let output = try kit.texture(.bgra8Unorm, 24, 8)
        let parameters = ComposeParameters(
            sharpen: 0, deband: 0, debandRadius: 8, debandThreshold: 0.02, frame: 0, vivid: 1, vividRadius: 4, dither: 0
        )
        try kit.run(try kit.pipeline("compose"), width: 24, height: 8) { encoder in
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            Kit.set(encoder, parameters, index: 0)
        }
        let result = kit.bytes(of: output, bytesPerPixel: 4)
        func level(_ x: Int) -> Int { Int(result[(4 * 24 + x) * 4 + 1]) }
        #expect(level(11) < 97, "the dark side of the edge gets darker: \(level(11))")
        #expect(level(12) > 143, "the bright side gets brighter: \(level(12))")
        #expect(isNear(UInt8(level(0)), 100, within: 1) && isNear(UInt8(level(23)), 140, within: 1), "flat areas are left alone")
        #expect(isNear(UInt8(level(5)), 100, within: 1) && isNear(UInt8(level(18)), 140, within: 1))
    }
}
