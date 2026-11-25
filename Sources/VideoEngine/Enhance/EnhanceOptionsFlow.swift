import Foundation

/// How much a new set of options changes what the chain has to do.
enum EnhanceOptionsChange: Equatable {
    case none
    /// Only how strong sharpen or deband are. Nothing is rebuilt and the governor keeps what it has learned: the
    /// scaler, its buffers and its demotions stay as they are.
    case tuning
    /// A different scaler setting, or the chain turning on or off: the ladder starts over.
    case structural
}

extension EnhanceOptions {
    func change(from old: EnhanceOptions) -> EnhanceOptionsChange {
        if self == old { return .none }
        if upscaler != old.upscaler || isEnabled != old.isEnabled { return .structural }
        return .tuning
    }
}

/// Holds back strength changes that arrive faster than the chain needs them, such as a slider dragged in steps of 0.05:
/// the first change applies at once, the ones that follow within `interval` wait, and only the newest of those applies
/// when the interval is over. A scaler or on/off change always applies at once, with the newest strengths.
struct OptionsCoalescer: Sendable, Equatable {
    static let interval: TimeInterval = 0.1

    private(set) var pending: EnhanceOptions?
    private var lastApplied: TimeInterval?

    /// Records a request. Returns the options to apply now, or nil when the request waits or changes nothing.
    mutating func request(_ options: EnhanceOptions, current: EnhanceOptions, now: TimeInterval) -> EnhanceOptions? {
        switch options.change(from: current) {
        case .none:
            pending = nil
            return nil
        case .structural:
            return apply(options, now: now)
        case .tuning:
            if let last = lastApplied, now - last < Self.interval {
                pending = options
                return nil
            }
            return apply(options, now: now)
        }
    }

    /// The held-back options, once the interval is over.
    mutating func due(current: EnhanceOptions, now: TimeInterval) -> EnhanceOptions? {
        guard let held = pending else { return nil }
        if held.change(from: current) == .none {
            pending = nil
            return nil
        }
        guard let last = lastApplied, now - last >= Self.interval else { return nil }
        return apply(held, now: now)
    }

    /// Seconds until held-back options may apply, or nil when nothing is held back.
    func delay(now: TimeInterval) -> TimeInterval? {
        guard pending != nil else { return nil }
        guard let last = lastApplied else { return 0 }
        return max(0, last + Self.interval - now)
    }

    private mutating func apply(_ options: EnhanceOptions, now: TimeInterval) -> EnhanceOptions {
        pending = nil
        lastApplied = now
        return options
    }
}
