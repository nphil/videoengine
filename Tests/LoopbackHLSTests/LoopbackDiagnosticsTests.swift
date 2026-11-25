import Foundation
import Network
import os
import Testing
@testable import LoopbackHLS

/// What the server reports about itself: one `loop-req` line for each request, `loop-state` lines for the
/// listener, and the same facts on demand. They are what a device log shows when a player stalls.
struct LoopbackDiagnosticsTests {
    private static let bytes = Data((0..<1000).map { UInt8($0 % 251) })

    @Test func logsEachRequestWithItsOutcome() async throws {
        let file = try GrowingFile(Self.bytes, available: 1000, complete: true)
        let capture = LogCapture()
        let playlist = "#EXTM3U\n#EXTINF:10.000,\nmedia.mp4\n#EXT-X-ENDLIST\n"
        let server = LoopbackServer(routes: [
            file.route("/media.mp4"),
            LoopbackRoute(path: "/index.m3u8", .playlist { playlist }),
        ], waitTimeout: 5, log: capture.sink)
        let base = try await server.start()
        defer { server.stop() }

        _ = try await RawHTTP.get(base, "/index.m3u8")
        _ = try await RawHTTP.get(base, "/media.mp4", range: "bytes=100-199")
        _ = try await RawHTTP.get(base, "/media.mp4", range: "bytes=2000-")
        _ = try await RawHTTP.get(base, "/missing")
        // The line is written when the send ends, which can be after the client has read the reply.
        let logged = try await eventually { capture.lines(tagged: "loop-req").count == 4 }
        #expect(logged)
        let requests = capture.lines(tagged: "loop-req")

        let list = try #require(requests.first { $0.field("path") == "/index.m3u8" })
        #expect(list.field("kind") == "playlist")
        #expect(list.field("range") == "-")
        #expect(list.field("status") == "200")
        #expect(list.number("bytes") == playlist.utf8.count)
        #expect(list.field("sent") == "ok")
        #expect(list.field("detail") == "segs:1,end:1")
        #expect(list.number("ms") != nil)
        #expect(list.number("conns") != nil)
        #expect(list.number("conn") != nil)

        let slice = try #require(requests.first { $0.field("range") == "bytes=100-199" })
        #expect(slice.field("kind") == "media")
        #expect(slice.field("path") == "/media.mp4")
        #expect(slice.field("status") == "206")
        #expect(slice.number("bytes") == 100)
        #expect(slice.field("sent") == "ok")

        let past = try #require(requests.first { $0.field("range") == "bytes=2000-" })
        #expect(past.field("status") == "416")
        #expect(past.field("detail") == "available:1000")
        #expect(past.number("bytes") == 0)

        let missing = try #require(requests.first { $0.field("path") == "/missing" })
        #expect(missing.field("kind") == "none")
        #expect(missing.field("status") == "404")

        // The ring and the counters tell the same story as the log.
        let recent = server.recentRequests()
        #expect(recent.count == 4)
        #expect(recent.allSatisfy { $0.hasPrefix("loop-req ") })
        #expect(recent.last?.field("path") == "/missing")
        let counted = try await eventually { server.diagnosticLines().first?.number("served") == 4 }
        #expect(counted)
        let state = try #require(server.diagnosticLines().first)
        #expect(state.number("accepted") == 4)
        #expect(state.number("aborted") == 0)
        #expect(state.number("pending") == 0)
    }

    @Test func namesTheFirstClientToAsk() async throws {
        let capture = LogCapture()
        let server = LoopbackServer(routes: [], waitTimeout: 1, log: capture.sink)
        let base = try await server.start()
        defer { server.stop() }

        _ = try await RawHTTP.get(base, "/first", userAgent: "AppleCoreMedia/1.0.0 (iPhone)")
        _ = try await RawHTTP.get(base, "/second", userAgent: "Other/2")

        let firsts = capture.lines(tagged: "loop-state").filter { $0.field("event") == "first-request" }
        #expect(firsts.count == 1)
        #expect(firsts.first?.field("client") == "AppleCoreMedia/1.0.0_(iPhone)")
    }

    @Test func reportsARequestThatIsStillWaitingForBytes() async throws {
        let file = try GrowingFile(Self.bytes, available: 500)
        let capture = LogCapture()
        // So long that only the update below can answer it, even on a simulator that freezes for seconds.
        let server = LoopbackServer(routes: [file.route("/media.mp4")], waitTimeout: 60, log: capture.sink)
        let base = try await server.start()
        defer { server.stop() }

        async let response = RawHTTP.get(base, "/media.mp4", range: "bytes=600-699")
        let waiting = try await eventually {
            server.diagnosticLines().contains { $0.hasPrefix("loop-req ") && $0.field("stage") == "waiting" }
        }
        #expect(waiting)

        let lines = server.diagnosticLines()
        let state = try #require(lines.first)
        #expect(state.hasPrefix("loop-state "))
        #expect(state.number("pending") == 1)
        #expect(state.number("conns") == 1)
        #expect(lines.count == 2)
        let request = try #require(lines.last)
        #expect(request.field("kind") == "media")
        #expect(request.field("range") == "bytes=600-699")
        #expect(request.field("status") == "pending")
        #expect(request.field("stage") == "waiting")
        #expect(server.recentRequests().count == 1)

        file.update(available: 1000, complete: false)
        server.contentChanged()
        let reply = try await response
        #expect(reply.status == 206)

        let settled = try await eventually { server.diagnosticLines().count == 1 }
        #expect(settled)
        let ended = try #require(capture.lines(tagged: "loop-req").last)
        #expect(ended.field("status") == "206")
        #expect(ended.field("sent") == "ok")
    }

    /// A hung request must be in the log before anything else happens to it: after 5 s it is reported while
    /// it is still pending, with the stage it is stuck in.
    @Test func reportsARequestThatStaysUnansweredWhileItIsStillPending() async throws {
        let file = try GrowingFile(Self.bytes, available: 500)
        let capture = LogCapture()
        let server = LoopbackServer(routes: [file.route("/media.mp4")], waitTimeout: 60, log: capture.sink)
        let base = try await server.start()
        defer { server.stop() }

        async let response = RawHTTP.get(base, "/media.mp4", range: "bytes=600-699")
        let reported = try await eventually(40) {
            capture.lines(tagged: "loop-state").contains { $0.field("event") == "request-slow" }
        }
        #expect(reported)
        let pending = capture.lines(tagged: "loop-req").filter { $0.field("status") == "pending" }
        let first = try #require(pending.first)
        #expect(first.field("stage") == "waiting")
        #expect((first.number("ms") ?? 0) >= 4000)

        file.update(available: 1000, complete: false)
        server.contentChanged()
        _ = try await response
    }

    @Test func reportsTheListenerInItsStateLine() async throws {
        let capture = LogCapture()
        let server = LoopbackServer(routes: [], waitTimeout: 1, log: capture.sink)
        let base = try await server.start()
        let port = try #require(base.port)

        let state = try #require(server.diagnosticLines().first)
        #expect(state.hasPrefix("loop-state "))
        #expect(state.field("listener") == "ready")
        #expect(state.number("port") == port)
        #expect(state.number("accepted") == 0)
        #expect(state.number("conns") == 0)
        #expect((state.number("fds") ?? 0) > 0)
        #expect((state.number("fd_limit") ?? 0) > 0)
        #expect(state.field("since_accept_ms") == "-")

        _ = try await RawHTTP.get(base, "/nothing")
        let served = try await eventually { server.diagnosticLines().first?.number("served") == 1 }
        #expect(served)
        #expect(server.diagnosticLines().first?.field("since_accept_ms") != "-")

        server.stop()
        #expect(server.diagnosticLines().first?.field("listener") == "stopped")
        let events = capture.lines(tagged: "loop-state").compactMap { $0.field("event") }
        #expect(events.contains("listener-ready"))
        #expect(events.last == "stopped")
    }

    /// iOS takes the listener away from a suspended app: the log must say so, and say it came back.
    @Test func logsTheLossOfTheListenerAndItsReturn() async throws {
        let file = try GrowingFile(Self.bytes, available: 1000)
        let capture = LogCapture()
        let server = LoopbackServer(routes: [file.route("/media.mp4")], waitTimeout: 5, log: capture.sink)
        let base = try await server.start()
        defer { server.stop() }
        let first = try #require(server.currentListener)

        server.lost(first)

        let back = try await eventually {
            server.currentListener.map { $0 !== first && $0.state == .ready } ?? false
        }
        #expect(back)
        let events = capture.lines(tagged: "loop-state").compactMap { $0.field("event") }
        #expect(events.contains("listener-lost"))
        #expect(events.contains("listener-relisten"))
        #expect(events.filter { $0 == "listener-ready" }.count >= 2)
        #expect(server.diagnosticLines().first?.field("listener") == "ready")
        let reply = try await RawHTTP.get(base, "/media.mp4", range: "bytes=0-9")
        #expect(reply.status == 206)
    }

    /// The server used to stop trying after five tries and say nothing: a player given its port then met
    /// "could not connect" until the app was restarted. Now it tries for about a minute, and when it gives
    /// up the log and the state line say so.
    @Test func saysSoWhenItCannotListenAgain() async throws {
        let capture = LogCapture()
        let made = OSAllocatedUnfairLock(initialState: 0)
        // The first listener is real; once the system takes it away, none can be made.
        let server = LoopbackServer(
            routes: [], queueLabel: "loopback-test", waitTimeout: 1, log: capture.sink, relistenLimit: 3,
            makeListener: { parameters in
                let count = made.withLock { value in
                    defer { value += 1 }
                    return value
                }
                if count == 0 { return try NWListener(using: parameters) }
                throw NWError.posix(.EADDRINUSE)
            }
        )
        _ = try await server.start()
        defer { server.stop() }
        let first = try #require(server.currentListener)

        server.lost(first)

        let gaveUp = try await eventually {
            capture.lines(tagged: "loop-state").contains { $0.field("event") == "listener-gave-up" }
        }
        #expect(gaveUp)
        let events = capture.lines(tagged: "loop-state").compactMap { $0.field("event") }
        #expect(events.contains("listener-lost"))
        #expect(events.filter { $0 == "listener-relisten" }.count == 3)
        #expect(events.filter { $0 == "listener-create-failed" }.count == 3)
        let state = try #require(server.diagnosticLines().first)
        #expect(state.field("listener") == "dead")
        #expect(state.number("relistens") == 3)
    }

    @Test func reportsAListenerThatCannotBeCreated() async throws {
        let capture = LogCapture()
        let server = LoopbackServer(
            routes: [], queueLabel: "loopback-test", waitTimeout: 1, log: capture.sink, relistenLimit: 1,
            makeListener: { _ in throw NWError.posix(.EADDRINUSE) }
        )

        await #expect(throws: LoopbackError.bindFailed) { try await server.start() }

        let events = capture.lines(tagged: "loop-state").compactMap { $0.field("event") }
        #expect(events.contains("listener-create-failed"))
        #expect(server.diagnosticLines().first?.field("listener") == "stopped")
    }

    @Test func pausesLongerBetweenListenAttemptsUpToTwoSeconds() {
        #expect(LoopbackServer.relistenPause(attempt: 1) == .zero)
        #expect(LoopbackServer.relistenPause(attempt: 2) == .milliseconds(200))
        #expect(LoopbackServer.relistenPause(attempt: 6) == .seconds(1))
        #expect(LoopbackServer.relistenPause(attempt: 11) == .seconds(2))
        #expect(LoopbackServer.relistenPause(attempt: 40) == .seconds(2))
    }
}
