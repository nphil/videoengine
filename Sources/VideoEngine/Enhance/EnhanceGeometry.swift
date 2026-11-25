import CoreGraphics
import Foundation

/// A window of a picture, in whole pixels.
struct PixelRect: Sendable, Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

/// How the player's frames have to be turned to stand upright: a quarter turn or a half turn, with or without a mirror.
/// Frames from `AVPlayerItemVideoOutput` come in the order the video was coded; the track's `preferredTransform` says
/// how the player turns them on screen, so the chain does the same.
///
/// The turn is written as an optional swap of the two axes followed by optional flips, which covers all eight
/// orientations a video can have. A phone held upright records a landscape picture with a 90 degree turn: the swap
/// and a flip across.
struct PictureOrientation: Sendable, Equatable, CustomStringConvertible {
    var swapsAxes: Bool
    /// After the swap, the picture is mirrored left to right.
    var flipsAcross: Bool
    /// After the swap, the picture is mirrored top to bottom.
    var flipsDown: Bool

    static let upright = PictureOrientation(swapsAxes: false, flipsAcross: false, flipsDown: false)

    init(swapsAxes: Bool, flipsAcross: Bool, flipsDown: Bool) {
        self.swapsAxes = swapsAxes
        self.flipsAcross = flipsAcross
        self.flipsDown = flipsDown
    }

    /// Reads a track's `preferredTransform`. Nil when it is not a turn by a multiple of 90 degrees, with or without a
    /// mirror (a scale or a skew, say): such a picture is not drawn right here.
    init?(transform: CGAffineTransform) {
        func unit(_ value: CGFloat) -> Int? {
            let rounded = value.rounded()
            guard value.isFinite, abs(value - rounded) < 0.02, abs(rounded) <= 1 else { return nil }
            return Int(rounded)
        }
        guard let a = unit(transform.a), let b = unit(transform.b), let c = unit(transform.c), let d = unit(transform.d) else {
            return nil
        }
        // The transform maps a coded point to a displayed one: x' = a x + c y and y' = b x + d y.
        if b == 0, c == 0, a != 0, d != 0 {
            self.init(swapsAxes: false, flipsAcross: a < 0, flipsDown: d < 0)
        } else if a == 0, d == 0, b != 0, c != 0 {
            self.init(swapsAxes: true, flipsAcross: c < 0, flipsDown: b < 0)
        } else {
            return nil
        }
    }

    var description: String {
        switch (swapsAxes, flipsAcross, flipsDown) {
        case (false, false, false): "upright"
        case (true, true, false): "turned 90 degrees"
        case (false, true, true): "turned 180 degrees"
        case (true, false, true): "turned 270 degrees"
        default: "mirrored"
        }
    }
}

/// What the video track says about how its frames are shown.
enum TrackOrientation: Sendable, Equatable {
    /// The track has not been read yet; the chain waits, and the player's picture shows.
    case loading
    case known(PictureOrientation)
    /// A transform the chain cannot draw, and why.
    case unsupported(String)

    init(transform: CGAffineTransform) {
        if let orientation = PictureOrientation(transform: transform) {
            self = .known(orientation)
        } else {
            self = .unsupported("the track's transform is not a quarter turn or a mirror")
        }
    }
}

/// What to turn the player's frames by, or why they cannot be drawn.
enum OrientationVerdict: Equatable {
    case use(PictureOrientation)
    case refuse(String)

    /// Settles the turn from the track and from what the player says it shows. `framesTurned` is whether the player's
    /// shown size has its sides the other way round from the coded frame's (nil when that cannot be told: no shown
    /// size yet, or a nearly square picture). When the player already shows the frames upright (the app set a video
    /// composition, which draws them turned) they are left as they are; when they are turned and the track does not
    /// say so, something else is going on and the picture is refused.
    static func resolve(track: TrackOrientation, framesTurned: Bool?) -> OrientationVerdict {
        switch track {
        case .loading:
            return .use(.upright)
        case .unsupported(let reason):
            return .refuse(reason)
        case .known(let orientation):
            guard let framesTurned else { return .use(orientation) }
            if orientation.swapsAxes == framesTurned { return .use(orientation) }
            if orientation.swapsAxes { return .use(.upright) }
            return .refuse("the player turns this clip in a way its track does not describe")
        }
    }
}

/// Where the shown picture is in the coded frame, and how it is turned: the crop (the clean aperture, rounded to even
/// numbers so the 4:2:0 chroma lines up), the turn, and the shape of a pixel once turned.
///
/// Every size is even, so a picture of any size works with 4:2:0 and with scalers that want even sizes: an odd
/// last row or column is cut off, and a crop is moved to an even corner. The picture loses at most a pixel on a side.
struct PictureGeometry: Sendable, Equatable {
    let coded: PixelSize
    let crop: PixelRect
    let orientation: PictureOrientation
    /// Width of one pixel over its height, for the upright picture.
    let pixelAspect: Double

    /// The upright picture's size: the crop, with its sides swapped for a quarter turn.
    var size: PixelSize {
        orientation.swapsAxes
            ? PixelSize(width: crop.height, height: crop.width)
            : PixelSize(width: crop.width, height: crop.height)
    }

    /// The frame needs nothing done to it.
    var isIdentity: Bool {
        orientation == .upright && crop.x == 0 && crop.y == 0 && crop.width == coded.width && crop.height == coded.height
    }

    /// Nil when the frame is smaller than 2x2 pixels. `clean` is the buffer's clean aperture, which is the whole frame
    /// when it has none, and `pixelAspect` is the shape of a coded pixel.
    static func make(coded: PixelSize, clean: CGRect, pixelAspect: Double, orientation: PictureOrientation) -> PictureGeometry? {
        let evenWidth = coded.width - coded.width % 2
        let evenHeight = coded.height - coded.height % 2
        guard evenWidth >= 2, evenHeight >= 2 else { return nil }
        var left = 0
        var top = 0
        var width = evenWidth
        var height = evenHeight
        if clean.width.isFinite, clean.height.isFinite, clean.width >= 2, clean.height >= 2 {
            left = evenFloor(min(max(whole(clean.minX, fallback: 0), 0), evenWidth - 2))
            top = evenFloor(min(max(whole(clean.minY, fallback: 0), 0), evenHeight - 2))
            width = evenFloor(min(max(whole(clean.width, fallback: evenWidth), 2), evenWidth - left))
            height = evenFloor(min(max(whole(clean.height, fallback: evenHeight), 2), evenHeight - top))
        }
        let aspect = pixelAspect.isFinite && pixelAspect > 0 ? pixelAspect : 1
        return PictureGeometry(
            coded: coded, crop: PixelRect(x: left, y: top, width: width, height: height), orientation: orientation,
            pixelAspect: orientation.swapsAxes ? 1 / aspect : aspect
        )
    }

    /// The coded pixel that lands on pixel (`x`, `y`) of the upright picture. The GPU kernels do the same arithmetic.
    func codedPixel(x: Int, y: Int) -> (x: Int, y: Int) {
        let upright = size
        let acrossed = orientation.flipsAcross ? upright.width - 1 - x : x
        let downed = orientation.flipsDown ? upright.height - 1 - y : y
        let swapped = orientation.swapsAxes ? (x: downed, y: acrossed) : (x: acrossed, y: downed)
        return (crop.x + swapped.x, crop.y + swapped.y)
    }

    private static func evenFloor(_ value: Int) -> Int { value - value % 2 }

    private static func whole(_ value: CGFloat, fallback: Int) -> Int {
        value.isFinite && abs(value) < 1e7 ? Int(value.rounded()) : fallback
    }
}
