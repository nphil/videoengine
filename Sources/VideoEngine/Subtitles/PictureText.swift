import CoreGraphics
import Foundation
import LoopbackHLS
import os
import Vision

// Text read from picture subtitles (PGS, DVB, VobSub), so AVPlayer can show them where the app cannot draw
// its own overlay: Picture in Picture and AirPlay. The design follows the feature as AetherEngine documents
// it (LGPL-3.0, github.com/superuser404notfound/AetherEngine); no code is taken from it.
//
// Each cue's pictures are flattened to one grey image, Vision reads the text, and the lines become a WebVTT
// cue with the picture's own start and end. The result is lossy by design: the overlay track stays the
// pixel-accurate rendering.

/// Reads the text of picture subtitles with Vision. Safe to call from any thread, but meant for one
/// worker at a time.
final class PictureTextRecognizer: Sendable {
    private struct State {
        var resolved = false
        var languages: [String]?
    }

    /// BCP-47 tag of the stream, "und" when unknown.
    private let languageTag: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(languageTag: String) {
        self.languageTag = languageTag
    }

    /// The cue text of one picture event: WebVTT-escaped lines, top to bottom; nil when nothing was read.
    func text(of bitmaps: [SubtitleBitmap]) -> String? {
        guard let image = PictureText.image(of: bitmaps),
              let lines = try? PictureText.recognize(image, languages: languages()) else { return nil }
        let text = PictureText.arrange(lines)
        return text.isEmpty ? nil : text.split(separator: "\n").map { WebVTT.escape(String($0)) }.joined(separator: "\n")
    }

    private func languages() -> [String]? {
        if let cached = state.withLock({ $0.resolved ? Optional($0.languages) : nil }) { return cached }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let resolved = PictureText.visionLanguage(for: languageTag, supported: supported).map { [$0] }
        state.withLock {
            $0.resolved = true
            $0.languages = resolved
        }
        return resolved
    }
}

enum PictureText {
    /// A line Vision read, with its box in the image: normalised, origin at the lower left.
    typealias Line = (text: String, box: CGRect)

    /// Pictures larger than this many pixels (after scaling) are not read.
    static let maxPixels = 24_000_000
    /// Margin around the pictures, in source pixels; Vision reads text at the image edge poorly.
    private static let padding = 12

    /// The pictures of one cue flattened to a grey image cropped to their union: composited over black when
    /// the text is light, which it nearly always is, over white when it is dark. Canvases under 720 lines
    /// (DVD) are doubled, as Vision wants text taller than the 20 or so pixels such pictures have.
    static func image(of bitmaps: [SubtitleBitmap]) -> CGImage? {
        let pictures = bitmaps.filter { $0.width > 0 && $0.height > 0 && $0.rgba.count >= $0.width * $0.height * 4 }
        guard let first = pictures.first else { return nil }
        let minX = pictures.map(\.x).min() ?? first.x
        let minY = pictures.map(\.y).min() ?? first.y
        let maxX = pictures.map { $0.x + $0.width }.max() ?? first.x
        let maxY = pictures.map { $0.y + $0.height }.max() ?? first.y
        let width = maxX - minX + 2 * padding
        let height = maxY - minY + 2 * padding
        let scale = first.canvasHeight < 720 ? 2 : 1
        guard width * height * scale * scale <= maxPixels else { return nil }

        // The brightest 10 % of the solid pixels are the fill; an outline is darker and fewer.
        var histogram = [Int](repeating: 0, count: 256)
        var solid = 0
        for picture in pictures {
            picture.rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
                for i in 0..<(picture.width * picture.height) where raw[i * 4 + 3] >= 128 {
                    histogram[luminance(raw[i * 4], raw[i * 4 + 1], raw[i * 4 + 2])] += 1
                    solid += 1
                }
            }
        }
        guard solid > 0 else { return nil }
        var seen = 0
        var fill = 255
        for level in stride(from: 255, through: 0, by: -1) {
            seen += histogram[level]
            if seen * 10 >= solid {
                fill = level
                break
            }
        }
        let background: UInt8 = fill >= 128 ? 0 : 255

        var grey = [UInt8](repeating: background, count: width * height)
        for picture in pictures {
            let left: Int = picture.x - minX + padding
            let top: Int = picture.y - minY + padding
            let pictureWidth: Int = picture.width
            let pictureHeight: Int = picture.height
            picture.rgba.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
                for row in 0..<pictureHeight {
                    for column in 0..<pictureWidth {
                        let i: Int = (row * pictureWidth + column) * 4
                        let alpha = Int(raw[i + 3])
                        if alpha == 0 { continue }
                        let o: Int = (top + row) * width + left + column
                        let level: Int = luminance(raw[i], raw[i + 1], raw[i + 2])
                        grey[o] = blend(Int(grey[o]), level, alpha)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(grey) as CFData),
              let flat = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        guard scale > 1 else { return flat }
        guard let context = CGContext(
            data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return flat }
        context.interpolationQuality = .high
        context.draw(flat, in: CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
        return context.makeImage() ?? flat
    }

    /// `level` over `behind` at `alpha` (0...255), both 0...255.
    private static func blend(_ behind: Int, _ level: Int, _ alpha: Int) -> UInt8 {
        let mixed: Int = behind * (255 - alpha) + level * alpha + 127
        return UInt8(mixed / 255)
    }

    private static func luminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        (Int(r) * 299 + Int(g) * 587 + Int(b) * 114) / 1000
    }

    /// The lines Vision reads in `image`, accurate level with language correction. `languages` is a
    /// recognition language Vision supports, or nil to let it detect the language.
    static func recognize(_ image: CGImage, languages: [String]?) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let languages {
            request.recognitionLanguages = languages
        } else {
            request.automaticallyDetectsLanguage = true
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox)
        }
    }

    /// Lines top to bottom, joined by newlines. Pieces of one line, which Vision may report apart across
    /// a wide gap, are joined left to right with a space.
    static func arrange(_ lines: [Line]) -> String {
        let usable = lines
            .map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), box: $0.box) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.box.midY > $1.box.midY }
        var rows: [[(text: String, box: CGRect)]] = []
        for line in usable {
            if let reference = rows.last?.first,
               abs(line.box.midY - reference.box.midY) < min(line.box.height, reference.box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    /// The recognition language Vision supports for a stream's language tag ("en" becomes "en-US"), or nil
    /// when the tag is unknown or Vision has none for it.
    static func visionLanguage(for tag: String, supported: [String]) -> String? {
        guard let primary = tag.split(separator: "-").first, tag != "und" else { return nil }
        let wanted = SubtitleLanguage.tag(String(primary)).lowercased()
        func code(_ identifier: String) -> String {
            (identifier.split(separator: "-").first.map(String.init) ?? identifier).lowercased()
        }
        let matches = supported.filter { code($0) == wanted }
        return matches.first { $0.lowercased() == tag.lowercased() } ?? matches.first
    }
}

/// Reads the pictures of one subtitle stream on a utility-priority queue and adds the text to the
/// rendition's track. The reading thread only enqueues: it never waits for Vision, and a backlog beyond
/// `capacity` events is dropped rather than held. The pictures are the overlay track's own buffers, so a
/// queued event costs no memory beyond them.
///
/// The track lists a slot once its source has been read `holdback` seconds past it, so this holds back
/// `readThrough` until every event read so far has been recognised: a listed slot never gains a cue.
final class PictureTextWorker: Sendable {
    typealias Recognize = @Sendable ([SubtitleBitmap]) -> String?

    private struct State {
        var pending = 0
        /// The latest position the reading thread has reported, as `SubtitleTrack.readThrough` takes it.
        var readThrough: TimeInterval = 0
        var dropped = 0
        var cancelled = false
    }

    let track: SubtitleTrack
    private let capacity: Int
    private let recognize: Recognize
    private let queue = DispatchQueue(label: "videoengine.subtitle-text", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(track: SubtitleTrack, capacity: Int = 512, recognize: @escaping Recognize) {
        self.track = track
        self.capacity = capacity
        self.recognize = recognize
    }

    convenience init(track: SubtitleTrack, languageTag: String) {
        let recognizer = PictureTextRecognizer(languageTag: languageTag)
        self.init(track: track, recognize: { recognizer.text(of: $0) })
    }

    /// Events dropped because the queue was full.
    var dropped: Int { state.withLock { $0.dropped } }

    /// The pictures grouped by event: one cue per start and end, in order of arrival.
    static func events(_ bitmaps: [SubtitleBitmap]) -> [[SubtitleBitmap]] {
        var events: [[SubtitleBitmap]] = []
        for bitmap in bitmaps {
            if let i = events.firstIndex(where: { $0[0].start == bitmap.start && $0[0].end == bitmap.end }) {
                events[i].append(bitmap)
            } else {
                events.append([bitmap])
            }
        }
        return events
    }

    /// Queues the pictures of one finished event, which share a start and an end. Returns false when the
    /// event was dropped, as the queue is full, or empty.
    @discardableResult
    func submit(_ event: [SubtitleBitmap]) -> Bool {
        guard let first = event.first, first.end > first.start else { return false }
        let watermark: TimeInterval? = state.withLock { s in
            guard !s.cancelled else { return nil }
            guard s.pending < capacity else {
                s.dropped += 1
                return nil
            }
            s.pending += 1
            return s.readThrough
        }
        guard let watermark else { return false }
        queue.async { [self] in
            let cancelled = state.withLock { $0.cancelled }
            if !cancelled, let text = recognize(event) {
                track.add(SubtitleCue(start: first.start, end: first.end, text: text))
            }
            let through = state.withLock { s -> TimeInterval in
                s.pending -= 1
                return s.pending == 0 ? s.readThrough : watermark
            }
            track.readThrough(through)
        }
        return true
    }

    /// The reading thread has read the source up to `served` seconds of the media file's timeline.
    func advance(to served: TimeInterval) {
        let idle = state.withLock { s -> Bool in
            s.readThrough = max(s.readThrough, served)
            return s.pending == 0
        }
        if idle { track.readThrough(served) }
    }

    /// No more events: once the queue has drained, the track is complete at `duration` seconds.
    func finish(duration: TimeInterval) {
        queue.async { [self] in
            guard !state.withLock({ $0.cancelled }) else { return }
            track.finish(duration: duration)
        }
    }

    /// The run is over; queued events are skipped.
    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    /// Returns once everything queued so far has been handled.
    func idle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }
}

extension RemuxSubtitle {
    /// What a run offers for a picture stream: its overlay entry as is and, when `recognizeText` is on, a
    /// WebVTT rendition named "<name> (text from picture)" next to it. The rendition carries the stream's
    /// language and its default, forced and hearing-impaired flags, as a text stream's would be.
    static func offered(
        picture: RemuxSubtitle, recognizeText: Bool, targetDuration: Int, unique: (String) -> String
    ) -> [RemuxSubtitle] {
        guard recognizeText else { return [picture] }
        var text = picture
        text.name = unique("\(picture.name) (text from picture)")
        text.overlay = nil
        text.webVTT = SubtitleTrack(targetDuration: targetDuration)
        text.isRecognizedFromPicture = true
        return [picture, text]
    }
}
