import Foundation
import Network
import os
import Testing
@testable import LoopbackHLS

/// A finished file under the traffic of a player that seeks: many ranged requests at once, requests
/// abandoned part-way, and clients that leave. Whatever the clients do, each request that stays must get
/// the right bytes, every connection must end, and the server must go on answering.
struct LoopbackStressTests {
    private struct Fetched: Sendable {
        var status: Int
        var contentRange: String?
        var body: Data
    }

    /// What went wrong, collected from many tasks.
    private final class Problems: Sendable {
        private let store = OSAllocatedUnfairLock(initialState: [String]())

        func add(_ text: String) { store.withLock { $0.append(text) } }

        var all: [String] { store.withLock { $0 } }
    }

    /// One ranged GET through URLSession, the client AVPlayer's loader is built on.
    private static func fetch(_ session: URLSession, _ base: URL, range: String) async throws -> Fetched {
        var request = URLRequest(url: base.appendingPathComponent("media.mp4"))
        request.setValue(range, forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (body, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        return Fetched(status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"), body: body)
    }

    private static func header(_ range: Range<Int>) -> String {
        "bytes=\(range.lowerBound)-\(range.upperBound - 1)"
    }

    /// A reason the answer is not the bytes of `range`, or nil when it is.
    private static func check(_ fetched: Fetched, _ range: Range<Int>, of content: Data) -> String? {
        guard fetched.status == 206 else { return "status \(fetched.status) for \(range)" }
        let expected = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(content.count)"
        guard fetched.contentRange == expected else {
            return "Content-Range \(fetched.contentRange ?? "none") for \(range), expected \(expected)"
        }
        guard fetched.body.count == range.count else { return "\(fetched.body.count) bytes for \(range)" }
        guard fetched.body == content[range] else { return "wrong bytes for \(range)" }
        return nil
    }

    @Test func answersEveryRequestOfAFinishedFileUnderCancellationsAndSeeks() async throws {
        let size = 24 << 20
        let content = Pattern.bytes(size)
        let file = try GrowingFile(content, available: Int64(size), complete: true)
        let capture = LogCapture()
        let server = LoopbackServer(routes: [file.route("/media.mp4")], waitTimeout: 30, log: capture.sink)
        let base = try await server.start()
        defer { server.stop() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 100
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let problems = Problems()
        var dice = Dice(seed: 20_261_124)

        // 1. Ranges the size of a segment, many at once, as a player reads ahead.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<160 {
                let length = 32_768 + dice.roll(1_000_000)
                let start = dice.roll(size - length)
                let range = start..<(start + length)
                group.addTask {
                    do {
                        let fetched = try await Self.fetch(session, base, range: Self.header(range))
                        if let problem = Self.check(fetched, range, of: content) { problems.add(problem) }
                    } catch {
                        problems.add("request for \(range) failed: \(error)")
                    }
                }
            }
        }

        // 2. Many connections at once, each its own socket, read by a client that sees every byte sent.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<48 {
                let length = 1 + dice.roll(600_000)
                let start = dice.roll(size - length)
                let range = start..<(start + length)
                group.addTask {
                    do {
                        let reply = try await RawHTTP.get(base, "/media.mp4", range: Self.header(range), timeout: 40)
                        let fetched = Fetched(status: reply.status, contentRange: reply.headers["content-range"],
                                              body: reply.body)
                        if let problem = Self.check(fetched, range, of: content) { problems.add(problem) }
                        if reply.headers["content-length"] != String(range.count) {
                            problems.add("Content-Length \(reply.headers["content-length"] ?? "none") for \(range)")
                        }
                    } catch {
                        problems.add("raw request for \(range) failed: \(error)")
                    }
                }
            }
        }

        // 3. Open-ended and suffix ranges, which a player uses to find out what a file is.
        let tail = try await Self.fetch(session, base, range: "bytes=\(size - 1000)-")
        if let problem = Self.check(tail, (size - 1000)..<size, of: content) { problems.add(problem) }
        let suffix = try await Self.fetch(session, base, range: "bytes=-500")
        if let problem = Self.check(suffix, (size - 500)..<size, of: content) { problems.add(problem) }

        // 4. Requests abandoned a few milliseconds in, as a seek abandons what was in flight. Whatever
        // became of each, it must end: a cancelled request that never returns is a hang.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<120 {
                let length = 200_000 + dice.roll(1_800_000)
                let start = dice.roll(size - length)
                let delay = dice.roll(8)
                let range = start..<(start + length)
                group.addTask {
                    let request = Task { try await Self.fetch(session, base, range: Self.header(range)) }
                    try? await Task.sleep(for: .milliseconds(delay))
                    request.cancel()
                    _ = await request.result
                }
            }
        }

        // 5. Seeks: reads queued ahead of the playhead, a jump that abandons them, then the reads after
        // the jump, which are the ones the player waits for.
        for _ in 0..<20 {
            let segment = 800_000 + dice.roll(1_200_000)
            let playhead = dice.roll(size - 6 * segment)
            var abandoned: [Task<Fetched, Error>] = []
            for step in 0..<3 {
                let start = playhead + step * segment
                let range = start..<(start + segment)
                abandoned.append(Task { try await Self.fetch(session, base, range: Self.header(range)) })
            }
            try await Task.sleep(for: .milliseconds(dice.roll(6)))
            for task in abandoned { task.cancel() }

            let target = dice.roll(size - 4 * segment)
            await withTaskGroup(of: Void.self) { group in
                for step in 0..<3 {
                    let range = (target + step * segment)..<(target + (step + 1) * segment)
                    group.addTask {
                        do {
                            let fetched = try await Self.fetch(session, base, range: Self.header(range))
                            if let problem = Self.check(fetched, range, of: content) { problems.add(problem) }
                        } catch {
                            problems.add("read after a seek, \(range), failed: \(error)")
                        }
                    }
                }
            }
            for task in abandoned { _ = await task.result }
        }

        // 6. Clients that leave: nothing said, half a header, a request never read, a reply read a little.
        for _ in 0..<5 {
            await withTaskGroup(of: Void.self) { group in
                for kind in RawHTTP.Abuse.allCases {
                    for _ in 0..<8 {
                        let start = dice.roll(size - 1_000_000)
                        let range = start..<(start + 1_000_000)
                        group.addTask {
                            do {
                                try await RawHTTP.abuse(kind, base, path: "/media.mp4", range: Self.header(range))
                            } catch {
                                problems.add("a client that \(kind) failed to connect: \(error)")
                            }
                        }
                    }
                }
            }
        }

        // Everything must end: no request left unanswered, no connection left open.
        let settled = try await eventually(40) {
            guard let state = server.diagnosticLines().first else { return false }
            return state.number("pending") == 0 && state.number("conns") == 0
        }
        let state = try #require(server.diagnosticLines().first)
        #expect(settled, "the server still holds work: \(state)")
        #expect(problems.all.isEmpty, "\(problems.all.prefix(8))")

        // Every request that began is in the log once, and the counters agree with it.
        let served = try #require(state.number("served"))
        let aborted = try #require(state.number("aborted"))
        let accounted = try await eventually {
            capture.lines(tagged: "loop-req").filter { $0.field("stage") == nil }.count == served + aborted
        }
        #expect(accounted, "served \(served), aborted \(aborted), logged \(capture.lines(tagged: "loop-req").count)")
        #expect(served + aborted >= 160 + 48 + 2 + 3 * 20)
        let odd = capture.lines(tagged: "loop-req").filter {
            $0.field("status") != "206" && $0.field("status") != "pending"
        }
        #expect(odd.isEmpty, "\(odd.prefix(5))")
        let slow = capture.lines(tagged: "loop-req").filter { $0.field("stage") != nil }
        #expect(slow.isEmpty, "requests that stayed unanswered for 5 s: \(slow.prefix(5))")
        #expect(server.recentRequests().count == 16)

        // Still alive: each kind of client gets its answer.
        let again = try await Self.fetch(session, base, range: "bytes=0-99")
        if let problem = Self.check(again, 0..<100, of: content) { problems.add(problem) }
        let raw = try await RawHTTP.get(base, "/media.mp4", range: "bytes=1000-1999", timeout: 40)
        #expect(raw.status == 206)
        #expect(raw.body == content[1000..<2000])
        #expect(problems.all.isEmpty, "\(problems.all.prefix(8))")
        #expect(server.diagnosticLines().first?.field("listener") == "ready")
    }
}
