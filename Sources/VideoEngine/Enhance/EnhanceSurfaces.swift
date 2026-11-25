import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import Metal

/// Why a stage could not start, in words a person can read.
struct EnhanceFailure: Error, CustomStringConvertible, Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// Carries a value to another thread when only one thread uses it at a time.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// One picture's storage for one stage: the texture the GPU works on and, for pool buffers, the pixel buffer behind it.
struct Surface {
    /// The picture, or for a two-plane 4:2:0 picture its luma plane.
    let texture: any MTLTexture
    /// The chroma plane of a two-plane 4:2:0 picture; nil for BGRA.
    let chroma: (any MTLTexture)?
    /// Set when the picture lives in a pixel buffer, as VideoToolbox needs.
    let buffer: CVPixelBuffer?
    /// What has to stay alive until the GPU is done with the texture.
    let holds: [AnyObject]

    init(texture: any MTLTexture, chroma: (any MTLTexture)? = nil, buffer: CVPixelBuffer?, holds: [AnyObject]) {
        self.texture = texture
        self.chroma = chroma
        self.buffer = buffer
        self.holds = holds
    }
}

/// Where the pictures of one stage live. Used from one thread at a time.
protocol SurfaceSource: AnyObject, Sendable {
    /// The storage for the next picture, or nil when every buffer is still in use.
    func next() -> Surface?
}

/// One private texture used for every picture: the GPU keeps the passes that share it in order.
final class PrivateSurfaces: SurfaceSource, @unchecked Sendable {
    private let surface: Surface

    init?(device: any MTLDevice, size: PixelSize, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.width, height: size.height, mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        surface = Surface(texture: texture, buffer: nil, holds: [])
    }

    func next() -> Surface? { surface }
}

/// Pixel buffers from a pool that never holds more than `ceiling` of them, each shown to Metal without a copy: BGRA, or
/// two-plane 4:2:0 as a scaler may ask. A buffer comes back to the pool when everything that holds it lets go.
final class PooledSurfaces: SurfaceSource, @unchecked Sendable {
    private let pool: CVPixelBufferPool
    private let cache: CVMetalTextureCache
    private let usage: MTLTextureUsage
    private let ceiling: Int
    private let format: ScalerFormat

    /// `requirements` are what a consumer asks of its buffers, such as a VideoToolbox scaler's attributes. The format,
    /// the size, IOSurface backing and Metal compatibility are always set here.
    init?(
        size: PixelSize, format: ScalerFormat = .bgra, requirements: [String: Any] = [:], usage: MTLTextureUsage, minimum: Int,
        ceiling: Int, cache: CVMetalTextureCache
    ) {
        var attributes = requirements
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = format.code
        attributes[kCVPixelBufferWidthKey as String] = size.width
        attributes[kCVPixelBufferHeightKey as String] = size.height
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        if attributes[kCVPixelBufferIOSurfacePropertiesKey as String] == nil {
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        }
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: minimum]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let pool = created else { return nil }
        self.pool = pool
        self.cache = cache
        self.usage = usage
        self.ceiling = ceiling
        self.format = format
    }

    func next() -> Surface? {
        var created: CVPixelBuffer?
        let auxiliary = [kCVPixelBufferPoolAllocationThresholdKey as String: ceiling] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxiliary, &created)
        guard status == kCVReturnSuccess, let buffer = created else { return nil }
        switch format {
        case .bgra:
            guard let wrapped = EnhanceTextures.wrap(buffer, plane: 0, format: .bgra8Unorm, cache: cache, usage: usage) else { return nil }
            return Surface(texture: wrapped.texture, buffer: buffer, holds: [wrapped.holder])
        case .nv12VideoRange:
            guard let luma = EnhanceTextures.wrap(buffer, plane: 0, format: .r8Unorm, cache: cache, usage: usage),
                  let chroma = EnhanceTextures.wrap(buffer, plane: 1, format: .rg8Unorm, cache: cache, usage: usage)
            else { return nil }
            return Surface(texture: luma.texture, chroma: chroma.texture, buffer: buffer, holds: [luma.holder, chroma.holder])
        }
    }
}

enum EnhanceTextures {
    /// The Metal texture for one plane of a pixel buffer, and the object that keeps it valid until the GPU is done.
    static func wrap(
        _ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache, usage: MTLTextureUsage
    ) -> (texture: any MTLTexture, holder: CVMetalTexture)? {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        let attributes = [kCVMetalTextureUsage as String: usage.rawValue] as CFDictionary
        var created: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, attributes, format, width, height, plane, &created
        )
        guard status == kCVReturnSuccess, let holder = created, let texture = CVMetalTextureGetTexture(holder) else { return nil }
        return (texture, holder)
    }
}
