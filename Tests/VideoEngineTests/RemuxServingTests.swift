import Foundation
import os
import Testing
@testable import VideoEngine

/// What AVPlayer is served from a finished run: the playlist, the bytes of every range it lists, and the
/// log lines the loopback server writes about each request.
struct RemuxServingTests {
    /// The lines the engine's logger receives, spelled as a device log spells them.
    private final class Lines: Sendable {
        private let store = OSAllocatedUnfairLock(initialState: [String]())

        var logger: EngineLogger {
            let store = self.store
            return EngineLogger(
                event: { tag, fields in
                    let line = ([tag] + fields.map { "\($0.0)=\($0.1)" }).joined(separator: " ")
                    store.withLock { $0.append(line) }
                },
                message: { _ in }
            )
        }

        var all: [String] { store.withLock { $0 } }

        /// The lines of one tag, such as `loop-req`.
        func tagged(_ tag: String) -> [String] { all.filter { $0.hasPrefix(tag + " ") } }
    }

    private struct Listing {
        var initSegment: Range<Int>
        var segments: [Range<Int>]
    }

    /// A track of the init segment.
    private struct TrackInfo {
        var id: UInt32
        var timescale: UInt32
        var handler: String
        var defaultDuration: UInt32
    }

    /// One track's part of a fragment: where it starts on the track's timeline, when the fragment says, and
    /// the sum of its sample durations.
    private struct TrackRun {
        var id: UInt32
        var start: UInt64?
        var duration: UInt64
    }

    /// Starts `session` and waits until its run has finished: the directory URL of its files, and its progress.
    private static func finish(_ session: RemuxSession) async throws -> (base: URL, progress: RemuxProgress) {
        let master = try await session.start()
        var finished: RemuxProgress?
        loop: for await event in session.events {
            switch event {
            case .finished(let progress):
                finished = progress
                break loop
            case .failed(let error, _):
                Issue.record("remux failed: \(error)")
                break loop
            case .stopped:
                break loop
            case .opened, .headerWritten, .timeline, .progress:
                continue
            }
        }
        let progress = try #require(finished)
        return (master.deletingLastPathComponent(), progress)
    }

    private static func get(_ client: URLSession, _ base: URL, _ path: String, range: Range<Int>? = nil)
        async throws -> (status: Int, body: Data, contentRange: String?)
    {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        }
        let (body, response) = try await client.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return (http.statusCode, body, http.value(forHTTPHeaderField: "Content-Range"))
    }

    /// The init segment and the segments a media playlist lists, as the byte ranges they cover.
    private static func listing(of playlist: String) -> Listing? {
        var initSegment: Range<Int>?
        var segments: [Range<Int>] = []
        for line in playlist.split(separator: "\n") {
            if line.hasPrefix("#EXT-X-MAP:") {
                let quoted = line.components(separatedBy: "BYTERANGE=\"").dropFirst().first?.prefix { $0 != "\"" }
                initSegment = quoted.flatMap { byteRange(String($0)) }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                if let parsed = byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count))) { segments.append(parsed) }
            }
        }
        guard let initSegment else { return nil }
        return Listing(initSegment: initSegment, segments: segments)
    }

    /// `<length>@<offset>` as the bytes it covers.
    private static func byteRange(_ attribute: String) -> Range<Int>? {
        let parts = attribute.split(separator: "@")
        guard parts.count == 2, let length = Int(parts[0]), let offset = Int(parts[1]), length > 0 else { return nil }
        return offset..<(offset + length)
    }

    /// The types of the top-level boxes that tile `data`, or nil when they do not tile it exactly.
    private static func boxTypes(_ data: Data) -> [String]? {
        var types: [String] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.endIndex - offset >= 8 else { return nil }
            let size = data[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard size >= 8, offset + size <= data.endIndex else { return nil }
            types.append(String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self))
            offset += size
        }
        return types
    }

    private static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        offset >= data.startIndex && offset < data.endIndex ? data[offset] : 0
    }

    /// Big-endian, and 0 past the end, so a malformed file fails a check instead of ending the test run.
    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= data.startIndex, offset + 4 <= data.endIndex else { return 0 }
        return data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        guard offset >= data.startIndex, offset + 8 <= data.endIndex else { return 0 }
        return data[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// The boxes laid end to end in `range` of `data`: each one's type and the range of its payload.
    private static func boxes(_ data: Data, in range: Range<Int>) -> [(type: String, payload: Range<Int>)] {
        var found: [(type: String, payload: Range<Int>)] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            let size = Int(be32(data, offset))
            guard size >= 8, offset + size <= range.upperBound else { break }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            found.append((type, (offset + 8)..<(offset + size)))
            offset += size
        }
        return found
    }

    /// The tracks of an init segment, with the sample duration their fragments fall back on.
    private static func tracks(inInitSegment data: Data) -> [TrackInfo] {
        guard let moov = boxes(data, in: data.startIndex..<data.endIndex).first(where: { $0.type == "moov" }) else {
            return []
        }
        var tracks: [TrackInfo] = []
        var defaults: [UInt32: UInt32] = [:]
        for box in boxes(data, in: moov.payload) {
            if box.type == "trak" {
                let children = boxes(data, in: box.payload)
                guard let tkhd = children.first(where: { $0.type == "tkhd" }),
                      let mdia = children.first(where: { $0.type == "mdia" }) else { continue }
                let media = boxes(data, in: mdia.payload)
                guard let mdhd = media.first(where: { $0.type == "mdhd" }),
                      let hdlr = media.first(where: { $0.type == "hdlr" }) else { continue }
                // Version 1 widens the creation and modification times from 32 to 64 bits.
                let id = be32(data, tkhd.payload.lowerBound + (byte(data, tkhd.payload.lowerBound) == 1 ? 20 : 12))
                let timescale = be32(data, mdhd.payload.lowerBound + (byte(data, mdhd.payload.lowerBound) == 1 ? 20 : 12))
                let handlerStart = hdlr.payload.lowerBound + 8
                let handlerEnd = min(handlerStart + 4, hdlr.payload.upperBound)
                let handler = handlerStart <= handlerEnd ? String(decoding: data[handlerStart..<handlerEnd], as: UTF8.self) : ""
                tracks.append(TrackInfo(id: id, timescale: timescale, handler: handler, defaultDuration: 0))
            } else if box.type == "mvex" {
                for trex in boxes(data, in: box.payload) where trex.type == "trex" {
                    defaults[be32(data, trex.payload.lowerBound + 4)] = be32(data, trex.payload.lowerBound + 12)
                }
            }
        }
        for index in tracks.indices { tracks[index].defaultDuration = defaults[tracks[index].id] ?? 0 }
        return tracks
    }

    /// Each track's start and length in a segment (`moof` + `mdat`), read from its `tfhd`, `tfdt` and `trun`.
    private static func trackRuns(in fragment: Data, tracks: [TrackInfo]) -> [TrackRun] {
        guard let moof = boxes(fragment, in: fragment.startIndex..<fragment.endIndex).first(where: { $0.type == "moof" }) else {
            return []
        }
        var runs: [TrackRun] = []
        for traf in boxes(fragment, in: moof.payload) where traf.type == "traf" {
            var id: UInt32 = 0
            var fallback: UInt32 = 0
            var start: UInt64?
            var duration: UInt64 = 0
            for box in boxes(fragment, in: traf.payload) {
                let first = box.payload.lowerBound
                switch box.type {
                case "tfhd":
                    let flags = be32(fragment, first) & 0xFF_FFFF
                    id = be32(fragment, first + 4)
                    fallback = tracks.first(where: { $0.id == id })?.defaultDuration ?? 0
                    var field = first + 8
                    if flags & 0x01 != 0 { field += 8 }  // base_data_offset
                    if flags & 0x02 != 0 { field += 4 }  // sample_description_index
                    if flags & 0x08 != 0 { fallback = be32(fragment, field) }
                case "tfdt":
                    start = byte(fragment, first) == 1 ? be64(fragment, first + 4) : UInt64(be32(fragment, first + 4))
                case "trun":
                    let flags = be32(fragment, first) & 0xFF_FFFF
                    let count = Int(be32(fragment, first + 4))
                    var field = first + 8
                    if flags & 0x01 != 0 { field += 4 }  // data_offset
                    if flags & 0x04 != 0 { field += 4 }  // first_sample_flags
                    // Each sample's record holds duration, size, flags and composition offset, as the flags select.
                    let stride = 4 * (flags & 0xF00).nonzeroBitCount
                    for _ in 0..<count {
                        if flags & 0x100 != 0 {
                            duration += UInt64(be32(fragment, field))
                            field += stride
                        } else {
                            duration += UInt64(fallback)
                        }
                    }
                default:
                    break
                }
            }
            runs.append(TrackRun(id: id, start: start, duration: duration))
        }
        return runs
    }

    private static func eventually(_ seconds: Double = 30, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func aFinishedRunServesEverySegmentItListsAndLogsTheRequests() async throws {
        let fixture = try Fixture.url("h264-aac-60s.mkv")
        let lines = Lines()
        let session = RemuxSession(sourceFactory: { try FileRangeSource(fileURL: fixture) }, logger: lines.logger)
        defer { session.stop() }
        // Only catches a hung run: simulator hosts have frozen test processes for over 10 s.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            session.stop()
        }
        defer { watchdog.cancel() }
        let (base, progress) = try await Self.finish(session)
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }

        let playlist = try await Self.get(client, base, "index.m3u8")
        #expect(playlist.status == 200)
        let text = String(decoding: playlist.body, as: UTF8.self)
        #expect(text.contains("#EXT-X-ENDLIST"))
        let listing = try #require(Self.listing(of: text))
        // One segment per keyframe, and the fixture has one a second.
        #expect(listing.segments.count >= 50)
        #expect(text.components(separatedBy: "#EXTINF:").count - 1 == listing.segments.count)

        // The ranges tile the file: the init segment, then each segment where the last one ended, and
        // after the last nothing but the muxer's trailer.
        #expect(listing.initSegment.lowerBound == 0)
        var next = listing.initSegment.upperBound
        for segment in listing.segments {
            #expect(segment.lowerBound == next)
            next = segment.upperBound
        }
        let written = Int(progress.bytesWritten)
        #expect(next <= written)
        #expect(written - next < 1 << 16)

        // Every range the playlist lists is served, and holds the boxes it should.
        let header = try await Self.get(client, base, "media.mp4", range: listing.initSegment)
        #expect(header.status == 206)
        #expect(Self.boxTypes(header.body) == ["ftyp", "moov"])
        for segment in listing.segments {
            let reply = try await Self.get(client, base, "media.mp4", range: segment)
            #expect(reply.status == 206, "segment \(segment)")
            #expect(reply.body.count == segment.count, "segment \(segment)")
            #expect(
                reply.contentRange?.hasPrefix("bytes \(segment.lowerBound)-\(segment.upperBound - 1)/") == true,
                "segment \(segment)"
            )
            #expect(Self.boxTypes(reply.body) == ["moof", "mdat"], "segment \(segment)")
        }

        // The server logged what it served: the playlist as AVPlayer would have seen it, each range with
        // its outcome, and its listener.
        let expectedMedia = listing.segments.count + 1
        let logged = try await Self.eventually {
            lines.tagged("loop-req").filter { $0.contains(" sent=ok") }.count >= expectedMedia + 1
        }
        #expect(logged)
        let requests = lines.tagged("loop-req")
        let media = requests.filter { $0.contains(" kind=media ") }
        #expect(media.count >= expectedMedia)
        #expect(media.allSatisfy { $0.contains(" status=206 ") && $0.contains(" sent=ok") })
        #expect(requests.contains { $0.contains(" kind=playlist ") && $0.contains(" detail=segs:\(listing.segments.count),end:1") })
        #expect(lines.tagged("loop-state").contains { $0.contains(" event=listener-ready ") })

        // And it is what a support screen shows.
        let report = EngineDiagnostics.report()
        #expect(report.contains("loop-req "))
        #expect(report.contains("loop-state "))
    }

    /// Segment requests repeated, overlapping and abandoned half way, as a player seeking back and forth
    /// makes them: all that stay are answered with the same bytes, and the server still answers after.
    @Test func aFinishedRunKeepsAnsweringWhileRequestsAreRepeatedAndAbandoned() async throws {
        let fixture = try Fixture.url("h264-aac-60s.mkv")
        let lines = Lines()
        let session = RemuxSession(sourceFactory: { try FileRangeSource(fileURL: fixture) }, logger: lines.logger)
        defer { session.stop() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            session.stop()
        }
        defer { watchdog.cancel() }
        let (base, _) = try await Self.finish(session)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 40
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }

        let playlist = try await Self.get(client, base, "index.m3u8")
        let listing = try #require(Self.listing(of: String(decoding: playlist.body, as: UTF8.self)))
        let ranges = [listing.initSegment] + listing.segments
        // What each range holds, from one request at a time.
        var once: [Range<Int>: Data] = [:]
        for range in ranges { once[range] = try await Self.get(client, base, "media.mp4", range: range).body }
        let truth = once

        let problems = OSAllocatedUnfairLock(initialState: [String]())
        let total = 400
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<total {
                let range = ranges[(index * 7 + index / 3) % ranges.count]
                let abandon = index % 3 == 0
                group.addTask {
                    if abandon {
                        let request = Task { try await Self.get(client, base, "media.mp4", range: range) }
                        try? await Task.sleep(for: .milliseconds(index % 5))
                        request.cancel()
                        _ = await request.result
                        return
                    }
                    do {
                        let reply = try await Self.get(client, base, "media.mp4", range: range)
                        if reply.status != 206 || reply.body != truth[range] {
                            problems.withLock { $0.append("range \(range): status \(reply.status), \(reply.body.count) bytes") }
                        }
                    } catch {
                        problems.withLock { $0.append("range \(range) failed: \(error)") }
                    }
                }
            }
        }
        #expect(problems.withLock { $0 }.isEmpty, "\(problems.withLock { $0 }.prefix(5))")

        // Every request that stayed was logged as answered; none was left waiting.
        let answered = (0..<total).filter { $0 % 3 != 0 }.count + ranges.count
        let settled = try await Self.eventually {
            lines.tagged("loop-req").filter { $0.contains(" status=206 ") && $0.contains(" sent=ok") }.count >= answered
        }
        #expect(settled)
        let waiting = lines.tagged("loop-req").filter { $0.contains(" stage=") }
        #expect(waiting.isEmpty, "\(waiting.prefix(5))")
        let odd = lines.tagged("loop-req").filter { !$0.contains(" status=206 ") && !$0.contains(" status=200 ") && !$0.contains(" status=pending ") }
        #expect(odd.isEmpty, "\(odd.prefix(5))")

        let last = try await Self.get(client, base, "media.mp4", range: listing.segments[0])
        #expect(last.status == 206)
        #expect(last.body == truth[listing.segments[0]])
    }

    /// What AVPlayer lays its timeline on: each track's segments must follow each other in time, and the
    /// lengths the playlist lists must be the ones the segments hold. A gap or an overlap at a boundary
    /// is a place where playback can stop although every request was answered.
    @Test(arguments: ["h264-aac-60s.mkv", "h264-aac.mkv", "hevc10-opus-srt.mkv"])
    func aFinishedRunsSegmentsFollowEachOtherInTime(fixtureName: String) async throws {
        let fixture = try Fixture.url(fixtureName)
        let session = RemuxSession(sourceFactory: { try FileRangeSource(fileURL: fixture) })
        defer { session.stop() }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(60))
            session.stop()
        }
        defer { watchdog.cancel() }
        let (base, _) = try await Self.finish(session)
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }

        let playlist = try await Self.get(client, base, "index.m3u8")
        let text = String(decoding: playlist.body, as: UTF8.self)
        let listing = try #require(Self.listing(of: text))
        let listed = text.split(separator: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { line in Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }) }
        #expect(listed.count == listing.segments.count)
        #expect(listing.segments.count >= 2)

        let header = try await Self.get(client, base, "media.mp4", range: listing.initSegment)
        let tracks = Self.tracks(inInitSegment: header.body)
        let video = try #require(tracks.first { $0.handler == "vide" })

        var previous: [UInt32: TrackRun] = [:]
        var firstStart: Double?
        var total = 0.0
        var problems: [String] = []
        for (index, segment) in listing.segments.enumerated() where index < listed.count {
            let reply = try await Self.get(client, base, "media.mp4", range: segment)
            for run in Self.trackRuns(in: reply.body, tracks: tracks) {
                guard let start = run.start else {
                    problems.append("segment \(index), track \(run.id): no tfdt")
                    continue
                }
                if let before = previous[run.id], let beforeStart = before.start, start != beforeStart + before.duration {
                    problems.append(
                        "segment \(index), track \(run.id) starts at \(start), where the one before ends at \(beforeStart + before.duration)"
                    )
                }
                previous[run.id] = run
                guard run.id == video.id else { continue }
                // The video segment's length is the length the playlist lists...
                let length = Double(run.duration) / Double(video.timescale)
                if abs(length - listed[index]) > 0.0006 {
                    problems.append("segment \(index) holds \(length) s of video and is listed as \(listed[index]) s")
                }
                // ...and it starts where the listed lengths before it add up to.
                let seconds = Double(start) / Double(video.timescale)
                let from = firstStart ?? seconds
                firstStart = from
                if abs((seconds - from) - total) > 0.0006 * Double(index) + 0.002 {
                    problems.append("segment \(index) starts \(seconds - from) s in; the playlist's lengths add up to \(total) s")
                }
                total += listed[index]
            }
        }
        #expect(problems.isEmpty, "\(problems.prefix(6))")
        #expect(previous[video.id] != nil)
    }
}
