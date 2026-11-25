import Foundation
import LoopbackHLS
import os

/// What the engine measured recently, for a support screen or a bug report: one `perf-*` line per
/// measured run, and the loopback server's `loop-req` and `loop-state` lines. Each stage behind the
/// `perf-*` lines is also an `os_signpost` interval (subsystem "VideoEngine", category "stages") for
/// Instruments.
public enum EngineDiagnostics {
    static let signposter = OSSignposter(subsystem: "VideoEngine", category: "stages")
    private static let capacity = 100
    private static let lines = OSAllocatedUnfairLock(initialState: [String]())
    /// The loopback lines have a ring of their own, so a busy player cannot push the `perf-*` lines out.
    private static let loopbackCapacity = 120
    private static let loopbackLines = OSAllocatedUnfairLock(initialState: [String]())
    /// The most recent loopback servers, newest last. `report()` asks them for their state.
    private static let servers = OSAllocatedUnfairLock(initialState: [WeakServer]())

    /// A loopback server held weakly: it ends with its run, not with the report.
    private struct WeakServer: Sendable {
        weak var server: LoopbackServer?
    }

    /// The recent lines, oldest first, one per line: the `perf-*` and `hw-*` lines, then the last
    /// `loop-req` and `loop-state` lines, then what the running loopback servers show now: their state
    /// and each request still unanswered.
    public static func report() -> String {
        var report = lines.withLock { $0 }
        report += loopbackLines.withLock { $0 }
        for server in servers.withLock({ $0.compactMap(\.server) }) { report += server.diagnosticLines() }
        return report.joined(separator: "\n")
    }

    /// `ProcessInfo.thermalState` as the report spells it.
    static func thermalState(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func note(_ line: String) {
        lines.withLock { lines in
            if lines.count == capacity { lines.removeFirst() }
            lines.append(line)
        }
    }

    static func noteLoopback(_ line: String) {
        loopbackLines.withLock { lines in
            if lines.count == loopbackCapacity { lines.removeFirst() }
            lines.append(line)
        }
    }

    /// Lets `report()` show `server` while it exists. Only the last four servers are kept.
    static func track(_ server: LoopbackServer) {
        servers.withLock { servers in
            servers.removeAll { $0.server == nil }
            servers.append(WeakServer(server: server))
            if servers.count > 4 { servers.removeFirst(servers.count - 4) }
        }
    }

    /// `tag key=value key=value`, a line of the report.
    static func line(_ tag: String, _ fields: [(String, String)]) -> String {
        ([tag] + fields.map { "\($0.0)=\($0.1)" }).joined(separator: " ")
    }
}

extension EngineLogger {
    /// Logs a measurement and keeps it for `EngineDiagnostics.report()`.
    func measurement(_ tag: String, _ fields: [(String, String)]) {
        event(tag, fields)
        EngineDiagnostics.note(EngineDiagnostics.line(tag, fields))
    }

    /// Logs a loopback server line and keeps it, in a ring of its own, for `EngineDiagnostics.report()`.
    func loopback(_ tag: String, _ fields: [(String, String)]) {
        event(tag, fields)
        EngineDiagnostics.noteLoopback(EngineDiagnostics.line(tag, fields))
    }
}

/// One timed stage: an `os_signpost` interval plus its duration in seconds. Confined to the thread that
/// began it.
struct StageTimer {
    private let name: StaticString
    private let interval: OSSignpostIntervalState
    private let start = DispatchTime.now()

    init(_ name: StaticString) {
        self.name = name
        interval = EngineDiagnostics.signposter.beginInterval(name, id: EngineDiagnostics.signposter.makeSignpostID())
    }

    func end() -> TimeInterval {
        EngineDiagnostics.signposter.endInterval(name, interval)
        return seconds(since: start)
    }
}

/// Marks a point in a run, such as its first sealed segment, and returns the seconds since the run began.
func milestone(_ name: StaticString, since start: DispatchTime) -> TimeInterval {
    EngineDiagnostics.signposter.emitEvent(name)
    return seconds(since: start)
}

func seconds(since start: DispatchTime) -> TimeInterval {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
}
