import CoreVideo
import Foundation

/// A pixel layout the chain can give a scaler or take back from one.
enum ScalerFormat: Sendable, Equatable {
    /// One plane of 8-bit BGRA, which the chain's own passes read and write directly.
    case bgra
    /// Two planes of 8-bit 4:2:0, video range ("420v"): what the player's frames are, and what Apple's real-time scaler takes.
    case nv12VideoRange

    var code: OSType {
        switch self {
        case .bgra: OSType(kCVPixelFormatType_32BGRA)
        case .nv12VideoRange: OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }

    var name: String {
        switch self {
        case .bgra: "BGRA"
        case .nv12VideoRange: "420v"
        }
    }
}

/// Which pixel format to use with a scaler, from what the scaler itself reports at run time. Nothing is assumed about
/// a particular scaler: a new OS release that changes what it takes changes the choice.
enum EnhanceFormats {
    /// The best format the chain can convert to or from that is among `offered`, or nil. BGRA comes first because the chain's
    /// own passes already work in it; 420v costs a copy in and a conversion out.
    static func choose(_ offered: [OSType]) -> ScalerFormat? {
        let preference: [ScalerFormat] = [.bgra, .nv12VideoRange]
        return preference.first { offered.contains($0.code) }
    }

    /// The formats a scaler takes for one side of its work. `supported` is the list its configuration reports;
    /// `attributes` is the pixel buffer requirement dictionary for that side, whose format key may be one value or a list.
    /// Where both name formats the common ones count; where only one does, that one.
    static func offered(attributes: [String: Any], supported: [OSType]) -> [OSType] {
        let listed = codes(attributes[kCVPixelBufferPixelFormatTypeKey as String])
        if listed.isEmpty { return supported }
        if supported.isEmpty { return listed }
        let common = listed.filter { supported.contains($0) }
        return common.isEmpty ? supported : common
    }

    /// `"BGRA 420v"` style text for a probe line.
    static func describe(_ codes: [OSType]) -> String {
        codes.map { EnhanceRungs.fourCC($0) }.joined(separator: " ")
    }

    private static func codes(_ value: Any?) -> [OSType] {
        guard let value else { return [] }
        if let list = value as? [Any] { return list.compactMap(code) }
        if let single = code(value) { return [single] }
        return []
    }

    private static func code(_ value: Any) -> OSType? {
        (value as? NSNumber)?.uint32Value
    }
}
