import Foundation
import os
import Testing
@testable import VideoEngine

/// A canned server for prewarm tests that records every request it gets. Each test uses its own host, so
/// tests run in parallel without seeing each other's requests.
final class PrewarmStub: URLProtocol, @unchecked Sendable {
    final class Site: Sendable {
        let body: Data
        let status: Int?
        private let log = OSAllocatedUnfairLock(initialState: [URLRequest]())

        init(body: Data, status: Int?) {
            self.body = body
            self.status = status
        }

        var requests: [URLRequest] { log.withLock { $0 } }
        var ranges: [String?] { requests.map { $0.value(forHTTPHeaderField: "Range") } }

        func record(_ request: URLRequest) { log.withLock { $0.append(request) } }
    }

    private static let sites = OSAllocatedUnfairLock(initialState: [String: Site]())

    /// A fresh host serving `body`, or answering every request with `status` when one is given.
    static func site(body: Data = Data(), status: Int? = nil) -> (url: URL, site: Site, configuration: URLSessionConfiguration) {
        let host = "prewarm-\(UUID().uuidString.lowercased()).test"
        let site = Site(body: body, status: status)
        sites.withLock { $0[host] = site }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrewarmStub.self]
        return (URL(string: "http://\(host)/video.mkv")!, site, configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return sites.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(), let site = Self.sites.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        site.record(request)
        let reply = site.status.map { FakeHTTP.Reply(status: $0) } ?? FakeHTTP.ranged(site.body)(request)
        var headers = reply.headers
        headers["Content-Length"] = String(reply.body.count)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct EnginePrewarmTests {
    private static func pattern(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 % 251) })
    }

    private func makeSource(_ url: URL, _ configuration: URLSessionConfiguration, headers: [String: String] = [:]) -> HTTPRangeSource {
        HTTPRangeSource(url: url, headers: headers, readAheadBytes: 0, requestTimeout: 60, retryWindow: 0, configuration: configuration)
    }

    @Test func aLaterSourceReadsItsHeadAndLengthWithoutARequest() async throws {
        let body = Self.pattern(count: 3 << 20)
        let (url, site, configuration) = PrewarmStub.site(body: body)
        let stored = await EnginePrewarm.prewarm(
            url: url, headers: [:], byteBudget: 1 << 20, configuration: configuration, cache: .shared
        )
        #expect(stored)
        #expect(site.ranges == ["bytes=0-1048575"])

        let source = makeSource(url, configuration)
        #expect(try source.length() == Int64(body.count))
        #expect(try source.bytes(at: 0, count: 64 << 10) == body.prefix(64 << 10))
        #expect(try source.bytes(at: 1000, count: 4000) == body.subdata(in: 1000..<5000))
        #expect(try source.bytes(at: (1 << 20) - 100, count: 100) == body.subdata(in: ((1 << 20) - 100)..<(1 << 20)))
        #expect(site.requests.count == 1)

        // Past the prewarmed bytes the source asks the server like any other.
        #expect(try source.bytes(at: 1 << 20, count: 1000) == body.subdata(in: (1 << 20)..<((1 << 20) + 1000)))
        #expect(site.requests.count == 2)
    }

    @Test func theBudgetLimitsTheRequest() async throws {
        let (url, site, configuration) = PrewarmStub.site(body: Self.pattern(count: 5000))
        let cache = PrewarmCache()
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 100, configuration: configuration, cache: cache))
        #expect(site.ranges == ["bytes=0-99"])
        let entry = try #require(cache.take(PrewarmCache.Key(url: url, headers: [:])))
        #expect(entry.bytes == Self.pattern(count: 100))
        #expect(entry.total == 5000)
    }

    @Test func aFileShorterThanTheBudgetIsHeldWhole() async throws {
        let body = Self.pattern(count: 1000)
        let (url, site, configuration) = PrewarmStub.site(body: body)
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 2 << 20, configuration: configuration, cache: .shared))
        let source = makeSource(url, configuration)
        #expect(try source.length() == 1000)
        #expect(try source.bytes(at: 0, count: 2000) == body)
        #expect(try source.bytes(at: 1000, count: 10).isEmpty)
        #expect(site.requests.count == 1)
    }

    @Test func theHeadersAreSentAndAreHalfOfTheKey() async throws {
        let body = Self.pattern(count: 4000)
        let (url, site, configuration) = PrewarmStub.site(body: body)
        let token = ["X-Plex-Token": "secret"]
        #expect(await EnginePrewarm.prewarm(url: url, headers: token, byteBudget: 2000, configuration: configuration, cache: .shared))
        #expect(site.requests.first?.value(forHTTPHeaderField: "X-Plex-Token") == "secret")

        // Other credentials, or none, do not see the bytes.
        let other = makeSource(url, configuration, headers: ["X-Plex-Token": "other"])
        #expect(try other.bytes(at: 0, count: 100) == body.prefix(100))
        #expect(site.requests.count == 2)
        let bare = makeSource(url, configuration)
        #expect(try bare.bytes(at: 0, count: 100) == body.prefix(100))
        #expect(site.requests.count == 3)

        // The same credentials do, whatever the case of the header name.
        let same = makeSource(url, configuration, headers: ["x-plex-token": "secret"])
        #expect(try same.length() == 4000)
        #expect(try same.bytes(at: 0, count: 100) == body.prefix(100))
        #expect(site.requests.count == 3)
    }

    @Test func theFirstSourceTakesTheBytesAndNoOtherDoes() async throws {
        let body = Self.pattern(count: 4000)
        let (url, site, configuration) = PrewarmStub.site(body: body)
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 2000, configuration: configuration, cache: .shared))
        let first = makeSource(url, configuration)
        #expect(try first.bytes(at: 0, count: 100) == body.prefix(100))
        #expect(site.requests.count == 1)
        // Reading the head again is still free for the source that took it.
        #expect(try first.bytes(at: 500, count: 100) == body.subdata(in: 500..<600))
        #expect(site.requests.count == 1)
        let second = makeSource(url, configuration)
        #expect(try second.bytes(at: 0, count: 100) == body.prefix(100))
        #expect(site.requests.count == 2)
    }

    @Test func aKnownLengthBeatsTheLengthTheServerGave() async throws {
        let (url, _, configuration) = PrewarmStub.site(body: Self.pattern(count: 4000))
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 2000, configuration: configuration, cache: .shared))
        let source = HTTPRangeSource(url: url, knownLength: 7777, readAheadBytes: 0, requestTimeout: 60, retryWindow: 0, configuration: configuration)
        #expect(try source.length() == 7777)
    }

    @Test func discardAllDropsWhatIsHeld() async throws {
        let body = Self.pattern(count: 4000)
        let (url, site, configuration) = PrewarmStub.site(body: body)
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 2000, configuration: configuration, cache: .shared))
        EnginePrewarm.discardAll()
        let source = makeSource(url, configuration)
        #expect(try source.bytes(at: 0, count: 100) == body.prefix(100))
        #expect(site.requests.count == 2)
    }

    @Test func aRefusedRequestLeavesNothingBehind() async throws {
        let (url, site, configuration) = PrewarmStub.site(status: 401)
        let cache = PrewarmCache()
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 1000, configuration: configuration, cache: cache) == false)
        #expect(site.requests.count == 1)
        #expect(cache.count == 0)
    }

    @Test func onlyHTTPURLsAreFetched() async {
        let cache = PrewarmCache()
        let file = URL(fileURLWithPath: "/tmp/video.mkv")
        #expect(await EnginePrewarm.prewarm(url: file, headers: [:], byteBudget: 1000, configuration: nil, cache: cache) == false)
        let (url, site, configuration) = PrewarmStub.site(body: Data(count: 10))
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 0, configuration: configuration, cache: cache) == false)
        #expect(site.requests.isEmpty)
    }

    @Test func aValidPrewarmIsNotFetchedAgain() async {
        let (url, site, configuration) = PrewarmStub.site(body: Self.pattern(count: 4000))
        let cache = PrewarmCache()
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 2000, configuration: configuration, cache: cache))
        #expect(await EnginePrewarm.prewarm(url: url, headers: [:], byteBudget: 2000, configuration: configuration, cache: cache))
        #expect(site.requests.count == 1)
    }
}

struct PrewarmCacheTests {
    private let url = URL(string: "https://nas.lan/video.mkv")!

    private func key(_ headers: [String: String] = [:]) -> PrewarmCache.Key { PrewarmCache.Key(url: url, headers: headers) }

    @Test func bytesExpireAfterTheirLifetime() {
        let now = OSAllocatedUnfairLock(initialState: UInt64(0))
        let cache = PrewarmCache(lifetime: 180, clock: { now.withLock { $0 } })
        cache.store(key(), bytes: Data(count: 10), total: 10)
        now.withLock { $0 = 179_000_000_000 }
        #expect(cache.contains(key()))
        now.withLock { $0 = 180_000_000_000 }
        #expect(!cache.contains(key()))
        #expect(cache.take(key()) == nil)
        #expect(cache.count == 0)
    }

    @Test func takingRemovesTheBytes() {
        let cache = PrewarmCache()
        cache.store(key(), bytes: Data([1, 2, 3]), total: 99)
        let entry = cache.take(key())
        #expect(entry?.bytes == Data([1, 2, 3]))
        #expect(entry?.total == 99)
        #expect(cache.take(key()) == nil)
    }

    @Test func removeAllEmptiesTheCache() {
        let cache = PrewarmCache()
        cache.store(key(), bytes: Data(count: 1), total: nil)
        cache.store(key(["A": "b"]), bytes: Data(count: 1), total: nil)
        cache.removeAll()
        #expect(cache.count == 0)
    }

    @Test func keepsTheNewestEightFiles() {
        let cache = PrewarmCache()
        for i in 0..<(PrewarmCache.maximumEntries + 2) { cache.store(key(["N": "\(i)"]), bytes: Data(count: 1), total: nil) }
        #expect(cache.count == PrewarmCache.maximumEntries)
        #expect(!cache.contains(key(["N": "0"])))
        #expect(!cache.contains(key(["N": "1"])))
        #expect(cache.contains(key(["N": "2"])))
        #expect(cache.contains(key(["N": "9"])))
    }

    @Test func keysIgnoreHeaderNameCaseAndOrderButNotValues() {
        #expect(key(["A-One": "x", "B-Two": "y"]) == key(["b-two": "y", "a-one": "x"]))
        #expect(key(["A-One": "x"]) != key(["A-One": "X"]))
        #expect(key() != PrewarmCache.Key(url: URL(string: "https://nas.lan/video.mkv?x=1")!, headers: [:]))
    }
}
