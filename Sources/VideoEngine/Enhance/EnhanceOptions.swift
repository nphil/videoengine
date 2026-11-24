import Foundation

/// What the picture enhancer does to the video. Every stage is optional and a value can change while the video plays:
/// assign it to `PictureEnhancer.options`. All stages off, the default, leaves the picture alone.
public struct EnhanceOptions: Sendable, Equatable {
    /// How the picture is made larger before the other stages run.
    public enum Upscaler: String, Sendable, Equatable, CaseIterable {
        /// Leave the size alone.
        case off
        /// The best scaler this device can keep up with. Apple's machine-learning scalers come first, then MetalFX,
        /// then a plain GPU Lanczos filter. Each is tried on the device and the first one that works is used.
        case automatic
        /// An edge-directed scaler for drawn pictures such as anime and cartoons: a Lanczos scale followed by a pass
        /// that steepens the lines. Written from the published idea behind Anime4K-style scalers.
        case lineArt
    }

    public var upscaler: Upscaler
    /// Contrast-adaptive sharpening: 0 is off, 1 is strongest. Values outside 0...1 are clamped.
    public var sharpen: Double { didSet { sharpen = Self.unit(sharpen) } }
    /// Banding removal: 0 is off, 1 is strongest. Values outside 0...1 are clamped.
    public var deband: Double { didSet { deband = Self.unit(deband) } }

    public init(upscaler: Upscaler = .off, sharpen: Double = 0, deband: Double = 0) {
        self.upscaler = upscaler
        self.sharpen = Self.unit(sharpen)
        self.deband = Self.unit(deband)
    }

    /// Every stage off.
    public static let off = EnhanceOptions()

    /// At least one stage is on.
    public var isEnabled: Bool { upscaler != .off || sharpen > 0 || deband > 0 }

    private static func unit(_ value: Double) -> Double {
        value.isNaN ? 0 : min(1, max(0, value))
    }
}

/// The scalers the enhancer can use. `rawValue` is the name diagnostics print.
public enum EnhanceUpscalerKind: String, Sendable, Equatable, CaseIterable {
    /// VideoToolbox's machine-learning super resolution, tuned for quality (iOS 26 and later).
    case videoToolboxSuperResolution = "vt-super-resolution"
    /// VideoToolbox's real-time machine-learning super resolution (iOS 26 and later; 1.5x added in iOS 27).
    case videoToolboxLowLatency = "vt-low-latency"
    /// MetalFX's spatial scaler on the GPU.
    case metalFXSpatial = "metalfx-spatial"
    /// The engine's own Lanczos-3 filter on the GPU.
    case lanczos
    /// The engine's own edge-directed line-art scaler on the GPU.
    case lineArt = "line-art"

    /// A plain-English name for a settings screen.
    public var label: String {
        switch self {
        case .videoToolboxSuperResolution: "Apple machine-learning super resolution"
        case .videoToolboxLowLatency: "Apple real-time machine-learning scaler"
        case .metalFXSpatial: "MetalFX scaler"
        case .lanczos: "GPU Lanczos scaler"
        case .lineArt: "Line-art scaler"
        }
    }
}

/// What the chain does to the picture right now.
public struct EnhancePlan: Sendable, Equatable {
    /// The scaler in use, nil when the picture is not being scaled: the source already fills the display,
    /// or only sharpening and debanding are on.
    public var upscaler: EnhanceUpscalerKind?
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var outputWidth: Int
    public var outputHeight: Int
    public var sharpen: Double
    public var deband: Double
}

/// Why the chain stepped aside and the plain picture shows. The chain comes back by itself.
public enum EnhancePauseReason: String, Sendable, Equatable {
    /// The device is hot or in Low Power Mode.
    case powerSaving
    /// The chain could not keep up with the video and was dropping frames.
    case droppedFrames
}

/// Why this picture is never enhanced. The plain picture shows for as long as it plays.
public enum EnhanceUnavailableReason: String, Sendable, Equatable {
    /// HDR and Dolby Vision are left to the system player. Only SDR is enhanced.
    case highDynamicRange
    /// No usable GPU, or its shaders would not compile.
    case noGPU
    /// The frames are in a form the chain does not handle: an unsupported pixel format or a cropped picture.
    case unsupportedPicture

    /// A plain-English sentence for a settings screen.
    public var message: String {
        switch self {
        case .highDynamicRange: "HDR and Dolby Vision play without enhancement."
        case .noGPU: "This device cannot run the enhancement shaders."
        case .unsupportedPicture: "This video's picture format is not supported by the enhancer."
        }
    }
}

public enum EnhanceState: Sendable, Equatable {
    /// Showing the plain picture and nothing to do: off, waiting for the first frame, or the source already fills the display.
    case idle
    /// The chain is drawing the picture.
    case running(EnhancePlan)
    /// The plain picture shows for now; the chain resumes by itself.
    case paused(EnhancePauseReason)
    /// The plain picture shows for as long as this video plays.
    case unavailable(EnhanceUnavailableReason)
}
