import CoreGraphics
import CoreText
import Foundation
import LoopbackHLS
import os
import Testing
@testable import VideoEngine

/// Picture subtitles read as text for Picture in Picture. A real remux over a picture stream cannot be
/// tested, as FFmpeg cannot encode PGS, DVB or VobSub from text, so these cover everything below the
/// demuxer: Vision on drawn text, the worker, the renditions the run offers and what it serves.
@Suite(.serialized)
struct PictureTextTests {
    // MARK: Drawing

    private struct Ink {
        var r: CGFloat, g: CGFloat, b: CGFloat
        static let white = Ink(r: 1, g: 1, b: 1)
        static let black = Ink(r: 0, g: 0, b: 0)
    }

    private static func makeContext(_ width: Int, _ height: Int) throws -> CGContext {
        try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    /// Draws `text` at `size` points with CoreText into `context`, baseline at `y` from the bottom.
    private static func draw(_ text: String, in context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(string as CFAttributedString)
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }

    /// Black text on white paper, as a plain document image.
    private static func paper(_ text: String) throws -> CGImage {
        let context = try Self.makeContext(720, 160)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 160))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        draw(text, in: context, x: 24, y: 52, size: 64)
        return try #require(context.makeImage())
    }

    /// A subtitle picture as a decoder makes it: transparent around the text, straight alpha. `outline`
    /// gives light text a dark edge, as PGS usually has.
    private static func bitmap(
        _ text: String, ink: Ink, outline: Bool = false, y: Int = 900, canvas: (Int, Int) = (1920, 1080),
        size: CGFloat = 60, start: TimeInterval = 1, end: TimeInterval = 3
    ) throws -> SubtitleBitmap {
        let width = 760
        let height = 110
        let context = try Self.makeContext(width, height)
        context.setFillColor(CGColor(red: ink.r, green: ink.g, blue: ink.b, alpha: 1))
        if outline {
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(5)
            context.setTextDrawingMode(.fillStroke)
        }
        draw(text, in: context, x: 20, y: 30, size: size)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Void in
            for i in 0..<(width * height) {
                let alpha = Int(bytes[i * 4 + 3])
                out[i * 4 + 3] = UInt8(alpha)
                guard alpha > 0 else { continue }
                // Premultiplied to straight.
                for c in 0..<3 { out[i * 4 + c] = UInt8(min(255, Int(bytes[i * 4 + c]) * 255 / alpha)) }
            }
        }
        return SubtitleBitmap(
            start: start, end: end, x: 200, y: y, width: width, height: height,
            canvasWidth: canvas.0, canvasHeight: canvas.1, rgba: rgba
        )
    }

    private static func recognizer(_ tag: String = "en") -> PictureTextRecognizer { PictureTextRecognizer(languageTag: tag) }

    // MARK: Vision

    /// Runs `work` off the test's thread and gives up after `seconds` (nil): Vision has stalled on
    /// simulators, and a test that hangs holds up the whole run.
    private static func within<T: Sendable>(_ seconds: Double = 90, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let answered = OSAllocatedUnfairLock(initialState: false)
            @Sendable func answer(_ value: T?) {
                let first = answered.withLock { taken -> Bool in
                    let was = taken
                    taken = true
                    return !was
                }
                if first { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).async { answer(work()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { answer(nil) }
        }
    }

    /// What Vision reads from the pictures of one event, lower-cased; empty when it reads nothing.
    private static func read(_ bitmaps: [SubtitleBitmap]) async throws -> String {
        let recognizer = Self.recognizer()
        let text = await within { recognizer.text(of: bitmaps) ?? "" }
        return try #require(text, "Vision did not answer within 90 s").lowercased()
    }

    @Test func readsDrawnTextFromAnImage() async throws {
        let image = try Self.paper("Hello world")
        let text = await Self.within { PictureText.arrange((try? PictureText.recognize(image, languages: nil)) ?? []) }
        #expect(try #require(text, "Vision did not answer within 90 s").lowercased() == "hello world")
    }

    @Test func readsAPictureSubtitleWithAnOutline() async throws {
        let picture = try Self.bitmap("Hello world", ink: .white, outline: true)
        #expect(try await Self.read([picture]) == "hello world")
    }

    @Test func readsDarkTextOnTransparency() async throws {
        let picture = try Self.bitmap("Hello world", ink: .black)
        #expect(try await Self.read([picture]) == "hello world")
    }

    @Test func readsSmallDVDCanvases() async throws {
        let picture = try Self.bitmap("Hello world", ink: .white, outline: true, y: 400, canvas: (720, 480), size: 30)
        #expect(try await Self.read([picture]) == "hello world")
    }

    @Test func readsTheLinesOfAnEventTopToBottom() async throws {
        // The lower picture first: the order of the pictures is not the order of the lines.
        let lower = try Self.bitmap("Good morning", ink: .white, outline: true, y: 940)
        let upper = try Self.bitmap("Hello world", ink: .white, outline: true, y: 820)
        #expect(try await Self.read([lower, upper]) == "hello world\ngood morning")
    }

    @Test func readsNothingFromABlankPicture() {
        let blank = SubtitleBitmap(
            start: 0, end: 1, x: 0, y: 0, width: 200, height: 60, canvasWidth: 1920, canvasHeight: 1080,
            rgba: Data(count: 200 * 60 * 4)
        )
        #expect(PictureText.image(of: [blank]) == nil)
        #expect(Self.recognizer().text(of: [blank]) == nil)
    }

    @Test func choosesTheBackgroundThatContrastsWithTheFill() throws {
        func corner(_ ink: Ink) throws -> UInt8 {
            let image = try #require(PictureText.image(of: [try Self.bitmap("Hi", ink: ink, outline: ink.r > 0.5)]))
            let data = try #require(image.dataProvider?.data) as Data
            return data[0]
        }
        #expect(try corner(.white) == 0)
        #expect(try corner(.black) == 255)
    }

    // MARK: Pure helpers

    @Test func arrangesLinesTopToBottomAndPiecesLeftToRight() {
        let lines: [PictureText.Line] = [
            ("second", CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1)),
            ("right", CGRect(x: 0.6, y: 0.62, width: 0.2, height: 0.1)),
            ("  ", CGRect(x: 0.1, y: 0.9, width: 0.1, height: 0.1)),
            ("left", CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.1)),
        ]
        #expect(PictureText.arrange(lines) == "left right\nsecond")
        #expect(PictureText.arrange([]) == "")
    }

    @Test func mapsStreamLanguagesToVisionLanguages() {
        let supported = ["en-US", "fr-FR", "de-DE", "zh-Hans", "zh-Hant"]
        #expect(PictureText.visionLanguage(for: "en", supported: supported) == "en-US")
        #expect(PictureText.visionLanguage(for: "fra", supported: supported) == "fr-FR")
        #expect(PictureText.visionLanguage(for: "zh-Hant", supported: supported) == "zh-Hant")
        #expect(PictureText.visionLanguage(for: "zh", supported: supported) == "zh-Hans")
        #expect(PictureText.visionLanguage(for: "und", supported: supported) == nil)
        #expect(PictureText.visionLanguage(for: "ja", supported: supported) == nil)
    }

    @Test func groupsPicturesIntoEventsByTime() throws {
        func picture(_ start: TimeInterval, _ end: TimeInterval) -> SubtitleBitmap {
            SubtitleBitmap(start: start, end: end, x: 0, y: 0, width: 1, height: 1, canvasWidth: 1, canvasHeight: 1, rgba: Data(count: 4))
        }
        let events = PictureTextWorker.events([picture(1, 2), picture(1, 2), picture(3, 4), picture(1, 5)])
        #expect(events.map(\.count) == [2, 1, 1])
        #expect(events.map { $0[0].start } == [1, 3, 1])
    }

    // MARK: Worker

    private static func picture(_ start: TimeInterval, _ end: TimeInterval) -> [SubtitleBitmap] {
        [SubtitleBitmap(start: start, end: end, x: 0, y: 0, width: 1, height: 1, canvasWidth: 1, canvasHeight: 1, rgba: Data(count: 4))]
    }

    @Test func turnsRecognisedEventsIntoTimedCuesAndSkipsEmptyOnes() async throws {
        let track = SubtitleTrack(targetDuration: 6)
        let worker = PictureTextWorker(track: track) { event in
            switch event[0].start {
            case 3: "Hello\nworld"
            case 6: nil
            case 9: "Spans &amp; slots"
            default: nil
            }
        }
        track.setOrigin(0)
        #expect(worker.submit(Self.picture(3, 5.5)))
        #expect(worker.submit(Self.picture(6, 7)))
        #expect(worker.submit(Self.picture(9, 13)))
        // Zero-length events are not cues.
        #expect(!worker.submit(Self.picture(14, 14)))
        worker.advance(to: 16)
        await worker.idle()
        #expect(track.slot(0) == """
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0

            00:00:03.000 --> 00:00:05.500
            Hello
            world

            00:00:09.000 --> 00:00:13.000
            Spans &amp; slots

            """)
        worker.finish(duration: 14)
        await worker.idle()
        #expect(try #require(track.slot(1)).contains("00:00:09.000 --> 00:00:13.000"))
        #expect(try #require(track.playlist(slotPrefix: "")).hasSuffix("#EXTINF:4.000,\n1.vtt\n#EXT-X-ENDLIST\n"))
    }

    @Test func listsASlotOnlyOnceItsPicturesAreRead() async throws {
        let gate = DispatchSemaphore(value: 0)
        let track = SubtitleTrack(targetDuration: 6)
        let worker = PictureTextWorker(track: track) { _ in
            gate.wait()
            return "Late"
        }
        track.setOrigin(0)
        #expect(worker.submit(Self.picture(2, 4)))
        // Production runs on; the picture is still being read, so nothing is listed.
        worker.advance(to: 30)
        #expect(track.playlist(slotPrefix: "") == nil)
        #expect(track.slot(0) == nil)
        gate.signal()
        await worker.idle()
        #expect(try #require(track.playlist(slotPrefix: "")).contains("\n1.vtt\n"))
        #expect(try #require(track.slot(0)).contains("00:00:02.000 --> 00:00:04.000\nLate"))
    }

    @Test func dropsEventsBeyondItsCapacityWithoutBlocking() async {
        let gate = DispatchSemaphore(value: 0)
        let track = SubtitleTrack(targetDuration: 6)
        let worker = PictureTextWorker(track: track, capacity: 2) { _ in
            gate.wait()
            return "x"
        }
        let accepted = (0..<5).map { worker.submit(Self.picture(TimeInterval($0), TimeInterval($0) + 1)) }
        #expect(accepted == [true, true, false, false, false])
        #expect(worker.dropped == 3)
        gate.signal()
        gate.signal()
        await worker.idle()
        // Room again once the queue drained.
        gate.signal()
        #expect(worker.submit(Self.picture(10, 11)))
        await worker.idle()
    }

    /// `DispatchSemaphore.wait` may not be called directly from async code.
    private static func block(_ semaphore: DispatchSemaphore) { semaphore.wait() }

    @Test func aCancelledWorkerSkipsItsQueueAndNeverFinishesTheTrack() async {
        let gate = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let track = SubtitleTrack(targetDuration: 6)
        let worker = PictureTextWorker(track: track) { _ in
            started.signal()
            gate.wait()
            reads.withLock { $0 += 1 }
            return "x"
        }
        track.setOrigin(0)
        worker.submit(Self.picture(1, 2))
        worker.submit(Self.picture(3, 4))
        Self.block(started)
        worker.cancel()
        worker.finish(duration: 10)
        gate.signal()
        await worker.idle()
        // The event already being read ends; the one behind it is skipped.
        #expect(reads.withLock { $0 } == 1)
        #expect(track.playlist(slotPrefix: "") == nil)
        #expect(!worker.submit(Self.picture(5, 6)))
    }

    // MARK: Renditions

    private static func pictureStream(name: String = "English", language: String = "en", isDefault: Bool = false, isForced: Bool = false) -> RemuxSubtitle {
        RemuxSubtitle(
            streamIndex: 3, name: name, language: language, isDefault: isDefault, isForced: isForced,
            overlay: SubtitleOverlayTrack()
        )
    }

    private static func offers(_ picture: RemuxSubtitle, recognizeText: Bool) -> [RemuxSubtitle] {
        var names = Set<String>([picture.name])
        return RemuxSubtitle.offered(picture: picture, recognizeText: recognizeText, targetDuration: 6) { name in
            var candidate = name
            var n = 2
            while !names.insert(candidate).inserted {
                candidate = "\(name) \(n)"
                n += 1
            }
            return candidate
        }
    }

    private static func run(_ subtitles: [RemuxSubtitle]) -> RemuxRun {
        let run = RemuxRun(fileURL: URL(fileURLWithPath: "/dev/null"), startTime: 0, openTimeout: 30, logger: .silent)
        run.setSubtitles(subtitles)
        run.headerWritten(HLSVariant(uri: "index.m3u8", bandwidth: 1_000_000))
        return run
    }

    @Test func offersNoExtraRenditionWhileTheOptionIsOff() throws {
        let off = Self.offers(Self.pictureStream(), recognizeText: false)
        #expect(off.count == 1)
        #expect(off[0].webVTT == nil)
        #expect(off[0].overlay != nil)
        #expect(!RemuxOptions().bitmapSubtitleText)
        let master = try #require(Self.run(off).multivariantPlaylist())
        #expect(!master.contains("EXT-X-MEDIA"))
        #expect(!master.contains("SUBTITLES="))
    }

    @Test func offersATextRenditionNextToThePictureStream() throws {
        let offered = Self.offers(Self.pictureStream(), recognizeText: true)
        #expect(offered.map(\.name) == ["English", "English (text from picture)"])
        #expect(offered.map(\.isRecognizedFromPicture) == [false, true])
        #expect(offered.map(\.streamIndex) == [3, 3])
        #expect(offered[0].overlay != nil && offered[0].webVTT == nil)
        #expect(offered[1].overlay == nil && offered[1].webVTT != nil)

        // Only the text is a rendition, named and tagged by language, and neither default nor autoselect.
        let master = try #require(Self.run(offered).multivariantPlaylist())
        #expect(master.contains("""
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English (text from picture)",LANGUAGE="en",\
            DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="subs/1/index.m3u8"
            """))
        #expect(master.components(separatedBy: "EXT-X-MEDIA").count == 2)
    }

    @Test func theTextRenditionFollowsTheStreamsFlags() throws {
        let forced = Self.offers(Self.pictureStream(isForced: true), recognizeText: true)
        #expect(try #require(Self.run(forced).multivariantPlaylist()).contains("DEFAULT=NO,AUTOSELECT=YES,FORCED=YES"))
        let standard = Self.offers(Self.pictureStream(isDefault: true), recognizeText: true)
        #expect(try #require(Self.run(standard).multivariantPlaylist()).contains("DEFAULT=YES,AUTOSELECT=YES,FORCED=NO"))
    }

    @Test func keepsRenditionNamesUnique() {
        var names = Set<String>(["English", "English (text from picture)"])
        let offered = RemuxSubtitle.offered(picture: Self.pictureStream(), recognizeText: true, targetDuration: 6) { name in
            var candidate = name
            var n = 2
            while !names.insert(candidate).inserted {
                candidate = "\(name) \(n)"
                n += 1
            }
            return candidate
        }
        #expect(offered.map(\.name) == ["English", "English (text from picture) 2"])
    }

    @Test func servesTheTextOfAPictureSequenceAsAWebVTTRendition() async throws {
        let offered = Self.offers(Self.pictureStream(), recognizeText: true)
        let track = try #require(offered[1].webVTT)
        let worker = PictureTextWorker(track: track) { event in
            switch event[0].start {
            case 2: "First line"
            case 4: "Second <line>".replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            default: nil
            }
        }
        let run = Self.run(offered)
        // The timeline starts 1 s into the movie, so served time is movie time minus 1.
        track.setOrigin(1)
        #expect(run.subtitleResponse("subs/1/index.m3u8") == nil, "no playlist until a slot is listed")

        worker.submit(Self.picture(2, 3.5))
        worker.submit(Self.picture(4, 6))
        worker.submit(Self.picture(7, 8))
        worker.advance(to: 16)
        await worker.idle()
        let playlist = try #require(run.subtitleResponse("subs/1/index.m3u8"))
        #expect(playlist.contentType == "application/vnd.apple.mpegurl")
        let listing = String(decoding: playlist.body, as: UTF8.self)
        #expect(listing.contains("#EXTINF:10.000,\n0.vtt\n"))
        #expect(!listing.contains("1.vtt"))
        #expect(!listing.contains("#EXT-X-ENDLIST"))
        let slot = try #require(run.subtitleResponse("subs/1/0.vtt"))
        #expect(slot.contentType == "text/vtt")
        #expect(String(decoding: slot.body, as: UTF8.self) == """
            WEBVTT
            X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0

            00:00:01.000 --> 00:00:02.500
            First line

            00:00:03.000 --> 00:00:05.000
            Second &lt;line&gt;

            """)
        #expect(run.subtitleResponse("subs/1/1.vtt") == nil)

        worker.finish(duration: 9)
        await worker.idle()
        let ended = String(decoding: try #require(run.subtitleResponse("subs/1/index.m3u8")).body, as: UTF8.self)
        #expect(ended.hasSuffix("#EXT-X-ENDLIST\n"))
        // The empty read of the last picture left no cue.
        #expect(!String(decoding: try #require(run.subtitleResponse("subs/1/0.vtt")).body, as: UTF8.self).contains("00:00:06"))
        // The overlay entry has no rendition to serve.
        #expect(run.subtitleResponse("subs/0/index.m3u8") == nil)
    }
}
