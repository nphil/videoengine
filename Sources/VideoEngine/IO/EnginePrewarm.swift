import Foundation
import os

/// Fetches the opening bytes of a remote file ahead of time, so the `HTTPRangeSource` made for it later
/// opens without waiting on the network: call it when a title is highlighted or about to start.
///
/// The bytes sit in memory under the URL and the exact headers. The first `HTTPRangeSource` made for the
/// same URL and headers takes them over, serves its first reads and its length from them and has no
/// request to make for those. They are dropped when taken, after three minutes, and when the system
/// reports memory pressure, whichever comes first, and at most eight prewarmed files are kept.
public enum EnginePrewarm {
    /// Most bytes one file may hold.
    public static let maximumByteBudget = 16 << 20

    /// Fetches the first `byteBudget` bytes (at most `maximumByteBudget`) of an `http://` or `https://`
    /// file. Returns true when bytes are held for the URL and headers afterwards, including from an
    /// earlier call that is still valid; false for other schemes, a failed or refused request, or a
    /// cancelled task, which then leaves nothing behind. A reply counts only when it is the requested
    /// bytes, on the same terms as `HTTPRangeSource`. A file shorter than the budget is held whole.
    ///
    /// A prewarm that is already running for the same URL and headers is not joined: both fetch.
    @discardableResult
    public static func prewarm(url: URL, headers: [String: String] = [:], byteBudget: Int = 2 << 20) async -> Bool {
        await prewarm(url: url, headers: headers, byteBudget: byteBudget, configuration: nil, cache: .shared)
    }

    /// Drops every prewarmed file.
    public static func discardAll() { PrewarmCache.shared.removeAll() }

    static func prewarm(
        url: URL, headers: [String: String], byteBudget: Int, configuration: URLSessionConfiguration?,
        cache: PrewarmCache
    ) async -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased()), byteBudget > 0 else { return false }
        let key = PrewarmCache.Key(url: url, headers: headers)
        if cache.contains(key) { return true }
        let limit = min(byteBudget, maximumByteBudget)
        let fetch = RangeFetch(start: 0, limit: limit, meter: TransferMeter())
        // A private transport lives only for this call; the shared one keeps its warm connections.
        let transport = configuration.map { HTTPTransport(configuration: $0) } ?? .shared
        let request = HTTPRangeSource.request(url: url, headers: headers, start: 0, limit: limit, timeout: 8)
        await withTaskCancellationHandler {
            fetch.attach(transport.start(request, for: fetch))
            // Wakes when the last byte has arrived or the request has ended.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = fetch.wait(for: Int64(limit - 1))
                    done.resume()
                }
            }
        } onCancel: {
            fetch.abandon()
        }
        withExtendedLifetime(transport) {}
        let bytes = fetch.bytes
        guard !Task.isCancelled, !bytes.isEmpty else { return false }
        cache.store(key, bytes: bytes, total: fetch.total)
        return true
    }
}

/// The prewarmed bytes, by URL and headers.
final class PrewarmCache: Sendable {
    static let shared = PrewarmCache(watchesMemory: true)

    /// Header names are case-insensitive; values are compared as sent.
    struct Key: Hashable, Sendable {
        let url: String
        let headers: [String]

        init(url: URL, headers: [String: String]) {
            self.url = url.absoluteString
            self.headers = headers.map { "\($0.key.lowercased()):\($0.value)" }.sorted()
        }
    }

    struct Entry: Sendable {
        let bytes: Data
        let total: Int64?
        let expires: UInt64
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        /// Oldest first.
        var order: [Key] = []
    }

    static let maximumEntries = 8
    private let lifetime: UInt64
    private let clock: @Sendable () -> UInt64
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let pressure = OSAllocatedUnfairLock<DispatchSourceMemoryPressure?>(uncheckedState: nil)

    init(
        lifetime: TimeInterval = 180, watchesMemory: Bool = false,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.lifetime = UInt64(lifetime * 1e9)
        self.clock = clock
        guard watchesMemory else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: DispatchQueue(label: "videoengine-prewarm-memory", qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.removeAll() }
        source.resume()
        pressure.withLockUnchecked { $0 = source }
    }

    deinit { pressure.withLockUnchecked { $0 }?.cancel() }

    var count: Int { state.withLock { $0.entries.count } }

    /// True when bytes that have not expired are held for `key`.
    func contains(_ key: Key) -> Bool {
        let now = clock()
        return state.withLock { s in
            purge(&s, now: now)
            return s.entries[key] != nil
        }
    }

    func store(_ key: Key, bytes: Data, total: Int64?) {
        let now = clock()
        let lifetime = lifetime
        state.withLock { s in
            purge(&s, now: now)
            s.order.removeAll { $0 == key }
            s.entries[key] = Entry(bytes: bytes, total: total, expires: now + lifetime)
            s.order.append(key)
            while s.order.count > Self.maximumEntries { s.entries[s.order.removeFirst()] = nil }
        }
        // The bytes go when their time is up even if nothing touches the cache again.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(Int(lifetime) + 100_000_000)) { [weak self] in
            guard let self else { return }
            let now = self.clock()
            self.state.withLock { self.purge(&$0, now: now) }
        }
    }

    /// Hands the bytes over and forgets them; nil when none are held or they have expired.
    func take(_ key: Key) -> Entry? {
        let now = clock()
        return state.withLock { s in
            purge(&s, now: now)
            guard let entry = s.entries.removeValue(forKey: key) else { return nil }
            s.order.removeAll { $0 == key }
            return entry
        }
    }

    func removeAll() {
        state.withLock { s in
            s.entries = [:]
            s.order = []
        }
    }

    private func purge(_ s: inout State, now: UInt64) {
        let expired = s.order.filter { (s.entries[$0]?.expires ?? 0) <= now }
        guard !expired.isEmpty else { return }
        for key in expired { s.entries[key] = nil }
        let live = s.entries
        s.order.removeAll { live[$0] == nil }
    }
}
