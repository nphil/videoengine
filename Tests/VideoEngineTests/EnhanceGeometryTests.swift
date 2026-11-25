import CoreGraphics
import Foundation
import Testing
@testable import VideoEngine

private func transform(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGAffineTransform {
    CGAffineTransform(a: a, b: b, c: c, d: d, tx: 0, ty: 0)
}

/// The eight orientations a video track can have, as `preferredTransform` matrices (translation left out).
private let allTransforms: [(name: String, matrix: CGAffineTransform)] = [
    ("upright", transform(1, 0, 0, 1)),
    ("90", transform(0, 1, -1, 0)),
    ("180", transform(-1, 0, 0, -1)),
    ("270", transform(0, -1, 1, 0)),
    ("mirrored across", transform(-1, 0, 0, 1)),
    ("mirrored down", transform(1, 0, 0, -1)),
    ("transposed", transform(0, 1, 1, 0)),
    ("anti-transposed", transform(0, -1, -1, 0)),
]

/// Where the centre of coded pixel (`x`, `y`) of a `width` x `height` picture lands when the player shows it with `t`,
/// in whole pixels of the shown picture (the shown picture's corner moved to the origin).
private func shown(_ t: CGAffineTransform, x: Int, y: Int, width: Int, height: Int) -> (x: Int, y: Int) {
    func map(_ px: Double, _ py: Double) -> (Double, Double) {
        (Double(t.a) * px + Double(t.c) * py, Double(t.b) * px + Double(t.d) * py)
    }
    let corners = [map(0, 0), map(Double(width), 0), map(0, Double(height)), map(Double(width), Double(height))]
    let minX = corners.map(\.0).min() ?? 0
    let minY = corners.map(\.1).min() ?? 0
    let centre = map(Double(x) + 0.5, Double(y) + 0.5)
    return (Int((centre.0 - minX).rounded(.down)), Int((centre.1 - minY).rounded(.down)))
}

struct PictureOrientationTests {
    @Test func readsTheEightQuarterTurnsAndMirrors() throws {
        let identity = try #require(PictureOrientation(transform: .identity))
        #expect(identity == .upright)
        // An iPhone held upright: coded landscape, shown by a quarter turn.
        let portrait = try #require(PictureOrientation(transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)))
        #expect(portrait == PictureOrientation(swapsAxes: true, flipsAcross: true, flipsDown: false))
        let half = try #require(PictureOrientation(transform: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)))
        #expect(half == PictureOrientation(swapsAxes: false, flipsAcross: true, flipsDown: true))
        let threeQuarters = try #require(PictureOrientation(transform: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)))
        #expect(threeQuarters == PictureOrientation(swapsAxes: true, flipsAcross: false, flipsDown: true))
        for (name, matrix) in allTransforms {
            #expect(PictureOrientation(transform: matrix) != nil, Comment(rawValue: name))
        }
        #expect(Set(allTransforms.compactMap { PictureOrientation(transform: $0.matrix) }.map(\.description)).count >= 4)
    }

    @Test func aScaleOrASkewIsNotAnOrientation() {
        #expect(PictureOrientation(transform: transform(2, 0, 0, 2)) == nil)
        #expect(PictureOrientation(transform: transform(1, 0, 0.5, 1)) == nil)
        #expect(PictureOrientation(transform: transform(0.7071, 0.7071, -0.7071, 0.7071)) == nil)
        #expect(PictureOrientation(transform: transform(0, 0, 0, 0)) == nil)
        #expect(PictureOrientation(transform: transform(CGFloat.nan, 0, 0, 1)) == nil)
        #expect(TrackOrientation(transform: transform(2, 0, 0, 2)) != .known(.upright))
    }

    @Test func aTransformWithRoundingNoiseIsStillAQuarterTurn() throws {
        let noisy = transform(0.00001, 0.99999, -0.99999, 0.00002)
        #expect(try #require(PictureOrientation(transform: noisy)).swapsAxes)
    }

    @Test func theTrackAndThePlayerAgreeOrTheClipIsHandledAnyway() {
        let turn = PictureOrientation(swapsAxes: true, flipsAcross: true, flipsDown: false)
        // The player's frames are coded on their side, as the track says.
        #expect(OrientationVerdict.resolve(track: .known(turn), framesTurned: true) == .use(turn))
        // Nothing to compare with yet: trust the track.
        #expect(OrientationVerdict.resolve(track: .known(turn), framesTurned: nil) == .use(turn))
        #expect(OrientationVerdict.resolve(track: .known(.upright), framesTurned: false) == .use(.upright))
        // The track says turned but the player already shows the frames upright (a video composition): leave them.
        #expect(OrientationVerdict.resolve(track: .known(turn), framesTurned: false) == .use(.upright))
        // The frames are turned and the track does not say so: refused.
        if case .refuse = OrientationVerdict.resolve(track: .known(.upright), framesTurned: true) {} else {
            Issue.record("a turn the track does not explain should be refused")
        }
        if case .refuse(let reason) = OrientationVerdict.resolve(track: .unsupported("a skew"), framesTurned: false) {
            #expect(reason == "a skew")
        } else {
            Issue.record("an unsupported transform should be refused")
        }
        // Mirrors and half turns keep the axes, so they agree with a frame that is not turned.
        let half = PictureOrientation(swapsAxes: false, flipsAcross: true, flipsDown: true)
        #expect(OrientationVerdict.resolve(track: .known(half), framesTurned: false) == .use(half))
    }

    @Test func framesTurnedComparesTheShownShapeWithTheCodedOne() {
        let landscape = PixelSize(width: 1920, height: 1080)
        #expect(FrameFacts.framesTurned(coded: landscape, pixelAspect: 1, shown: CGSize(width: 1080, height: 1920)) == true)
        #expect(FrameFacts.framesTurned(coded: landscape, pixelAspect: 1, shown: CGSize(width: 1920, height: 1080)) == false)
        #expect(FrameFacts.framesTurned(coded: landscape, pixelAspect: 1, shown: .zero) == nil)
        // A nearly square picture cannot say.
        #expect(FrameFacts.framesTurned(coded: PixelSize(width: 1000, height: 990), pixelAspect: 1, shown: CGSize(width: 990, height: 1000)) == nil)
        // DVD widescreen is coded 720x480 and shown 853x480: not turned.
        #expect(FrameFacts.framesTurned(coded: PixelSize(width: 720, height: 480), pixelAspect: 32.0 / 27.0, shown: CGSize(width: 853, height: 480)) == false)
        // Coded sideways with wide pixels, shown upright: turned.
        #expect(FrameFacts.framesTurned(coded: PixelSize(width: 1280, height: 720), pixelAspect: 4.0 / 3.0, shown: CGSize(width: 960, height: 1280)) == true)
    }
}

struct PictureGeometryTests {
    private func make(
        _ width: Int, _ height: Int, clean: CGRect? = nil, aspect: Double = 1, orientation: PictureOrientation = .upright
    ) -> PictureGeometry? {
        PictureGeometry.make(
            coded: PixelSize(width: width, height: height),
            clean: clean ?? CGRect(x: 0, y: 0, width: width, height: height), pixelAspect: aspect, orientation: orientation
        )
    }

    @Test func evenSizesPassThroughUntouched() throws {
        for (width, height) in [(320, 176), (426, 240), (854, 480), (960, 544), (1016, 572), (1920, 1080), (720, 1280)] {
            let geometry = try #require(make(width, height))
            #expect(geometry.size == PixelSize(width: width, height: height))
            #expect(geometry.isIdentity)
        }
    }

    @Test func oddSizesLoseTheirOddRowAndColumnAndAreNeverRefused() throws {
        let odd = try #require(make(853, 481))
        #expect(odd.size == PixelSize(width: 852, height: 480))
        #expect(odd.crop == PixelRect(x: 0, y: 0, width: 852, height: 480))
        #expect(!odd.isIdentity)
        let thin = try #require(make(3, 5))
        #expect(thin.size == PixelSize(width: 2, height: 4))
        let smallest = try #require(make(2, 2))
        #expect(smallest.size == PixelSize(width: 2, height: 2))
        for (width, height) in [(1, 1), (1, 100), (100, 1), (0, 0), (3, 1)] {
            #expect(make(width, height) == nil, Comment(rawValue: "\(width)x\(height)"))
        }
    }

    @Test func everySizeIsEvenWhateverTheInput() throws {
        for width in 2...41 {
            for height in [2, 3, 7, 18, 33] {
                let geometry = try #require(make(width, height))
                #expect(geometry.crop.width % 2 == 0 && geometry.crop.height % 2 == 0)
                #expect(geometry.crop.x % 2 == 0 && geometry.crop.y % 2 == 0)
                #expect(geometry.crop.x + geometry.crop.width <= width && geometry.crop.y + geometry.crop.height <= height)
            }
        }
    }

    @Test func aCleanApertureCropsTheFrame() throws {
        // The usual 1080p coded as 1088 rows, with the aperture 1080 rows at the top.
        let hd = try #require(make(1920, 1088, clean: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        #expect(hd.size == PixelSize(width: 1920, height: 1080))
        #expect(hd.crop.y == 0)
        // An aperture with its own corner: kept to even numbers.
        let inset = try #require(make(1920, 1088, clean: CGRect(x: 4, y: 4, width: 1912, height: 1080)))
        #expect(inset.crop == PixelRect(x: 4, y: 4, width: 1912, height: 1080))
        // An odd corner and size move to even ones, never outside the frame.
        let odd = try #require(make(1920, 1088, clean: CGRect(x: 1, y: 1, width: 1917, height: 1077)))
        #expect(odd.crop == PixelRect(x: 0, y: 0, width: 1916, height: 1076))
        // Fractions round.
        let fractional = try #require(make(200, 100, clean: CGRect(x: 0.4, y: 0.4, width: 100.4, height: 50.4)))
        #expect(fractional.crop == PixelRect(x: 0, y: 0, width: 100, height: 50))
        // An aperture that runs past the edge is held inside it.
        let past = try #require(make(200, 100, clean: CGRect(x: 150, y: 0, width: 100, height: 100)))
        #expect(past.crop == PixelRect(x: 150, y: 0, width: 50, height: 100))
        // An empty, huge or broken aperture means the whole frame.
        let notANumber = CGFloat.nan
        for clean in [CGRect.zero, CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: notANumber, y: 0, width: notANumber, height: notANumber),
                      CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 50)] {
            let whole = try #require(make(200, 100, clean: clean))
            #expect(whole.size == PixelSize(width: 200, height: 100), Comment(rawValue: "\(clean)"))
        }
    }

    @Test func aQuarterTurnSwapsTheSizeAndInvertsThePixelShape() throws {
        let turn = PictureOrientation(swapsAxes: true, flipsAcross: true, flipsDown: false)
        let portrait = try #require(make(1920, 1080, orientation: turn))
        #expect(portrait.size == PixelSize(width: 1080, height: 1920))
        #expect(!portrait.isIdentity)
        let dvd = try #require(make(720, 480, aspect: 32.0 / 27.0, orientation: turn))
        #expect(dvd.size == PixelSize(width: 480, height: 720))
        #expect(abs(dvd.pixelAspect - 27.0 / 32.0) < 1e-9)
        let flat = try #require(make(720, 480, aspect: 32.0 / 27.0))
        #expect(abs(flat.pixelAspect - 32.0 / 27.0) < 1e-9)
        // A broken pixel shape is a square pixel.
        for broken in [0.0, -1.0, Double.nan, Double.infinity] {
            let geometry = try #require(make(64, 64, aspect: broken))
            #expect(geometry.pixelAspect == 1)
        }
    }

    @Test func aCroppedAndTurnedPictureTakesItsSizeFromTheCrop() throws {
        let turn = PictureOrientation(swapsAxes: true, flipsAcross: false, flipsDown: true)
        let geometry = try #require(make(1920, 1088, clean: CGRect(x: 0, y: 0, width: 1920, height: 1080), orientation: turn))
        #expect(geometry.size == PixelSize(width: 1080, height: 1920))
        #expect(geometry.crop.height == 1080)
    }

    @Test func everyUprightPixelComesFromTheCodedPixelThePlayerShowsThere() throws {
        // Coded 12x8 with a clean window of 6x4 at (2, 2): all eight orientations, checked against the transform itself.
        for (name, matrix) in allTransforms {
            let orientation = try #require(PictureOrientation(transform: matrix))
            let geometry = try #require(make(12, 8, clean: CGRect(x: 2, y: 2, width: 6, height: 4), orientation: orientation))
            let upright = geometry.size
            #expect(upright == (orientation.swapsAxes ? PixelSize(width: 4, height: 6) : PixelSize(width: 6, height: 4)))
            var seen = Set<[Int]>()
            for y in 0..<upright.height {
                for x in 0..<upright.width {
                    let coded = geometry.codedPixel(x: x, y: y)
                    #expect(coded.x >= 2 && coded.x < 8 && coded.y >= 2 && coded.y < 6, Comment(rawValue: "\(name) \(x),\(y)"))
                    seen.insert([coded.x, coded.y])
                    let landed = shown(
                        matrix, x: coded.x - geometry.crop.x, y: coded.y - geometry.crop.y,
                        width: geometry.crop.width, height: geometry.crop.height
                    )
                    #expect(landed.x == x && landed.y == y, Comment(rawValue: "\(name): upright \(x),\(y) came from coded \(coded) which is shown at \(landed)"))
                }
            }
            #expect(seen.count == upright.pixels, Comment(rawValue: "\(name) reads each coded pixel once"))
        }
    }

    @Test func aBlockOfChromaStaysABlockWhateverTheTurn() throws {
        // The 2x2 luma block of an upright pixel pair comes from one 2x2 block of the coded frame, so 4:2:0 chroma lines up.
        for (name, matrix) in allTransforms {
            let orientation = try #require(PictureOrientation(transform: matrix))
            let geometry = try #require(make(16, 10, clean: CGRect(x: 2, y: 4, width: 10, height: 6), orientation: orientation))
            for y in stride(from: 0, to: geometry.size.height, by: 2) {
                for x in stride(from: 0, to: geometry.size.width, by: 2) {
                    var blocks = Set<[Int]>()
                    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                        let coded = geometry.codedPixel(x: x + dx, y: y + dy)
                        blocks.insert([coded.x >> 1, coded.y >> 1])
                    }
                    #expect(blocks.count == 1, Comment(rawValue: "\(name) at \(x),\(y)"))
                }
            }
        }
    }
}

/// The sizes of amateur video: phone clips, old web video, odd crops. The planner and the output math must give a
/// sensible, in-budget, same-shape result for all of them, on a landscape and on a portrait display.
struct AmateurSizeTests {
    private static let landscapePhone = PixelSize(width: 2556, height: 1179)
    private static let portraitPhone = PixelSize(width: 1179, height: 2556)
    private static let sizes: [(Int, Int)] = [
        (320, 176), (426, 240), (640, 360), (854, 480), (960, 544), (1016, 572), (1440, 1080), (720, 1280), (1080, 1920),
        (480, 854), (544, 960), (852, 480), (1280, 720), (1920, 1080), (2, 2), (4, 2), (640, 8),
    ]

    private func picture(_ size: PixelSize, aspect: Double = 1) -> SourcePicture {
        SourcePicture(size: size, pixelAspect: aspect)
    }

    @Test func everyFreeOutputKeepsTheShapeAndStaysInBudget() {
        for target in [Self.landscapePhone, Self.portraitPhone] {
            for (width, height) in Self.sizes {
                let source = PixelSize(width: width, height: height)
                let scale = EnhanceMath.fitScale(source: picture(source), target: target)
                #expect(scale > 0 && scale.isFinite)
                guard let output = EnhanceMath.freeOutput(source: source, scale: scale) else { continue }
                let label = Comment(rawValue: "\(source) on \(target) -> \(output)")
                #expect(output.pixels <= EnhanceMath.maximumOutputPixels + output.width + output.height, label)
                #expect(Double(output.width) / Double(source.width) <= EnhanceMath.maximumScale + 0.001, label)
                #expect(Double(output.height) / Double(source.height) <= EnhanceMath.maximumScale + 0.001, label)
                // Shape: width over height changes by no more than the rounding of one pixel.
                let wanted = Double(width) / Double(height)
                let made = Double(output.width) / Double(output.height)
                #expect(abs(made - wanted) <= wanted / Double(output.height) + wanted / Double(output.width) + 1e-9, label)
                #expect(output.width >= width && output.height >= height, label)
            }
        }
    }

    @Test func smallPicturesGetTheMostTheLadderAllows() {
        // 320x176 and 426x240 wanted more than 4x: held to 4x, still under the pixel budget.
        #expect(EnhanceMath.freeOutput(source: PixelSize(width: 320, height: 176), scale: EnhanceMath.fitScale(source: picture(PixelSize(width: 320, height: 176)), target: Self.landscapePhone)) == PixelSize(width: 1280, height: 704))
        #expect(EnhanceMath.freeOutput(source: PixelSize(width: 426, height: 240), scale: EnhanceMath.fitScale(source: picture(PixelSize(width: 426, height: 240)), target: Self.landscapePhone)) == PixelSize(width: 1704, height: 960))
    }

    @Test func portraitVideoFitsAPortraitDisplayAndNotALandscapeOne() {
        let portrait = PixelSize(width: 720, height: 1280)
        let onPortrait = EnhanceMath.fitScale(source: picture(portrait), target: Self.portraitPhone)
        #expect(abs(onPortrait - 1179.0 / 720.0) < 1e-9)
        #expect(EnhanceMath.freeOutput(source: portrait, scale: onPortrait) == PixelSize(width: 1179, height: 2096))
        // On a landscape phone it is shown smaller than it is: nothing to upscale.
        let onLandscape = EnhanceMath.fitScale(source: picture(portrait), target: Self.landscapePhone)
        #expect(onLandscape < 1)
        #expect(EnhanceMath.freeOutput(source: portrait, scale: onLandscape) == nil)
        // Full HD portrait on the portrait phone is within 10% of the screen: left to the display's scaler.
        let hd = PixelSize(width: 1080, height: 1920)
        #expect(EnhanceMath.freeOutput(source: hd, scale: EnhanceMath.fitScale(source: picture(hd), target: Self.portraitPhone)) == nil)
    }

    @Test func nonSquarePixelsFitByTheirShownShape() {
        // A 1440x1080 clip with 4:3 pixels is shown 1920x1080.
        let wide = picture(PixelSize(width: 1440, height: 1080), aspect: 4.0 / 3.0)
        #expect(abs(EnhanceMath.fitScale(source: wide, target: PixelSize(width: 3840, height: 2160)) - 2) < 1e-9)
        // The same clip with square pixels is 4:3.
        let square = picture(PixelSize(width: 1440, height: 1080))
        #expect(abs(EnhanceMath.fitScale(source: square, target: PixelSize(width: 3840, height: 2160)) - 2) < 1e-9)
        // PAL widescreen, 720x576 with 64:45 pixels, is shown 1024x576.
        let pal = picture(PixelSize(width: 720, height: 576), aspect: 64.0 / 45.0)
        #expect(abs(EnhanceMath.fitScale(source: pal, target: PixelSize(width: 1024, height: 2000)) - 1) < 1e-9)
        // A turned picture has its pixel shape inverted by the geometry: 27:32 pixels in a 480x720 portrait.
        let portraitDVD = picture(PixelSize(width: 480, height: 720), aspect: 27.0 / 32.0)
        #expect(abs(EnhanceMath.fitScale(source: portraitDVD, target: PixelSize(width: 405, height: 720)) - 1) < 1e-9)
    }

    @Test func aFixedFactorScalerSeesEverySizeThroughTheBudget() {
        // 4x only, as the quality scaler offers on the iPhone 17 Pro: fine for small pictures and for 480p-class ones (v3.1.0:
        // the result is scaled down to the display), skipped above that.
        let small = EnhanceMath.fixedFactor(needed: 6.7, source: PixelSize(width: 320, height: 176), from: [4])
        #expect(small == .use(4))
        #expect(EnhanceMath.fixedFactor(needed: 4.9, source: PixelSize(width: 426, height: 240), from: [4]) == .use(4))
        #expect(EnhanceMath.fixedFactor(needed: 2, source: PixelSize(width: 854, height: 480), from: [4]) == .use(4))
        for (width, height) in [(720, 1280), (1080, 1920), (1280, 720), (960, 544)] {
            let verdict = EnhanceMath.fixedFactor(needed: 2, source: PixelSize(width: width, height: height), from: [4])
            #expect(verdict == .skip("only 4x, too costly for live video"), Comment(rawValue: "\(width)x\(height): \(verdict)"))
        }
        // A scaler with several factors takes the nearest affordable one for an odd shape.
        #expect(EnhanceMath.fixedFactor(needed: 2.06, source: PixelSize(width: 1016, height: 572), from: [1.5, 2, 3, 4]) == .use(2))
        #expect(EnhanceMath.scaled(PixelSize(width: 1016, height: 572), by: 2) == PixelSize(width: 2032, height: 1144))
        #expect(EnhanceMath.scaled(PixelSize(width: 852, height: 480), by: 1.5) == PixelSize(width: 1278, height: 720))
    }

    @Test func theMatrixGuessIsTheSameWhicheverWayTheFrameIsCoded() {
        let cases: [(Int, Int, YCbCrMatrix)] = [
            (1280, 720, .bt709), (720, 1280, .bt709), (1080, 1920, .bt709), (1920, 1080, .bt709), (1440, 1080, .bt709),
            (960, 720, .bt709), (720, 960, .bt709),
            (854, 480, .bt601), (480, 854, .bt601), (640, 480, .bt601), (576, 1024, .bt601), (1016, 572, .bt601), (320, 176, .bt601),
        ]
        for (width, height, matrix) in cases {
            #expect(YCbCrMatrix.assumed(for: PixelSize(width: width, height: height)) == matrix, Comment(rawValue: "\(width)x\(height)"))
        }
    }

    @Test func everySizeIsPlannedWithoutBeingRefused() {
        for target in [Self.landscapePhone, Self.portraitPhone] {
            for (width, height) in Self.sizes {
                let size = PixelSize(width: width, height: height)
                let scale = EnhanceMath.fitScale(source: picture(size), target: target)
                var statuses: [EnhanceUpscalerKind: RungStatus] = [:]
                if let output = EnhanceMath.freeOutput(source: size, scale: scale) { statuses[.lanczos] = .ready(output) }
                let context = EnhanceContext(
                    options: EnhanceOptions(upscaler: .automatic, sharpen: 0.5, deband: 0), source: picture(size), target: target,
                    statuses: statuses
                )
                let decision = EnhanceMath.decide(context)
                guard case .run(let plan) = decision else {
                    Issue.record(Comment(rawValue: "\(size) on \(target): \(decision)"))
                    continue
                }
                #expect(plan.sourceWidth == width && plan.sourceHeight == height)
                #expect(plan.outputWidth >= width && plan.outputHeight >= height)
            }
        }
    }

    @Test func aRefusedPictureIsUnavailableWhateverItsSize() {
        var refused = picture(PixelSize(width: 1080, height: 1920))
        refused.refusal = "the track's transform is not a quarter turn or a mirror"
        let context = EnhanceContext(options: EnhanceOptions(sharpen: 1), source: refused, target: Self.portraitPhone)
        #expect(EnhanceMath.decide(context) == .unavailable(.unsupportedPicture))
    }
}
