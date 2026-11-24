import Foundation
import os
import Security

/// Trust for HTTPS hosts the system does not trust: a media server on the home network with a self-signed
/// certificate or one from a private certificate authority.
///
/// The hook applies to every `HTTPRangeSource` and `EnginePrewarm` request, so also to the sources the
/// engine makes itself from a URL (probe, remux, frame extraction).
public enum EngineTLS {
    /// Decides whether to trust the server behind `host`; `trust` holds its certificate chain.
    public typealias ServerTrustEvaluator = @Sendable (_ host: String, _ trust: SecTrust) -> Bool

    private static let evaluator = OSAllocatedUnfairLock<ServerTrustEvaluator?>(initialState: nil)

    /// Asked on every server-trust challenge of the engine's HTTP sessions. `true` accepts the connection and
    /// `false` ends it. The system's own verdict is not applied first, so a hook that returns `true` for a
    /// host also accepts a bad certificate there: compare the host and the leaf certificate (for example
    /// its SHA-256 fingerprint, stored when the user first accepted it), and call
    /// `SecTrustEvaluateWithError` yourself to keep the system's decision for hosts you do not recognise.
    /// `nil`, the default, leaves every decision to the system.
    public static var serverTrustEvaluator: ServerTrustEvaluator? {
        get { evaluator.withLock { $0 } }
        set { evaluator.withLock { $0 = newValue } }
    }

    /// How the session answers an authentication challenge.
    static func resolve(
        method: String, host: String, trust: SecTrust?, evaluator: ServerTrustEvaluator?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard method == NSURLAuthenticationMethodServerTrust, let trust, let evaluator else {
            return (.performDefaultHandling, nil)
        }
        return evaluator(host, trust) ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}
