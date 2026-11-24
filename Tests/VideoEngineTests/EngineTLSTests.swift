import Foundation
import os
import Security
import Testing
@testable import VideoEngine

@Suite(.serialized)
struct EngineTLSTests {
    /// A self-signed certificate for CN=nas.lan, never evaluated: the tests only need a real `SecTrust`.
    private static let certificate = Data(base64Encoded: """
    MIIBezCCASGgAwIBAgIUaAztT/V8kBL0CgmdXt+/suk2TKYwCgYIKoZIzj0EAwIwEjEQMA4GA1UEAwwHbmFzLmxhbjAgFw0yNjExMjQxNDExMDJaGA8yMTI2MTAzMTE0MTEwMlowEjEQMA4GA1UEAwwHbmFzLmxhbjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABB1gftKPcKOidXCRA2v1jAT9VoKsgwwWc/u3iJoQGNldJnT25nIvs96R2qOtt0D9KxmkjFmx+v3Cy2oHtEOylYWjUzBRMB0GA1UdDgQWBBTpS1rlBlt7EKtfOnko1DKVJObDOjAfBgNVHSMEGDAWgBTpS1rlBlt7EKtfOnko1DKVJObDOjAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQDHtW/w4AstYWxQX1GvlcJ6piY/JeVSiBkIZNLZn9vCAgIgS2OF4kFBcw+g6o20mKkrRQoVPZ19nUZDRdTN/AJii78=
    """)!

    private func makeTrust() throws -> SecTrust {
        let certificate = try #require(SecCertificateCreateWithData(nil, Self.certificate as CFData))
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "nas.lan" as CFString), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    private let serverTrust = NSURLAuthenticationMethodServerTrust

    @Test func withoutAHookTheSystemDecides() throws {
        let (disposition, credential) = EngineTLS.resolve(method: serverTrust, host: "nas.lan", trust: try makeTrust(), evaluator: nil)
        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test func aHookThatTrustsAcceptsTheConnectionWithThatTrust() throws {
        let trust = try makeTrust()
        let (disposition, credential) = EngineTLS.resolve(method: serverTrust, host: "nas.lan", trust: trust, evaluator: { _, _ in true })
        #expect(disposition == .useCredential)
        #expect(credential != nil)
    }

    @Test func aHookThatDistrustsEndsTheConnection() throws {
        let (disposition, credential) = EngineTLS.resolve(method: serverTrust, host: "nas.lan", trust: try makeTrust(), evaluator: { _, _ in false })
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
    }

    @Test func theHookSeesTheHostAndTheCertificate() throws {
        let trust = try makeTrust()
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        _ = EngineTLS.resolve(method: serverTrust, host: "nas.lan", trust: trust, evaluator: { host, trust in
            let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
            let subject = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            seen.withLock { $0 = [host, subject ?? "none"] }
            return true
        })
        #expect(seen.withLock { $0 } == ["nas.lan", "nas.lan"])
    }

    @Test func otherChallengesAreLeftToTheSystem() throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (disposition, _) = EngineTLS.resolve(
            method: NSURLAuthenticationMethodHTTPBasic, host: "nas.lan", trust: nil, evaluator: { _, _ in false }
        )
        #expect(disposition == .performDefaultHandling)
        // A server-trust challenge without trust has nothing to ask about.
        let (missing, _) = EngineTLS.resolve(method: serverTrust, host: "nas.lan", trust: nil, evaluator: { _, _ in calls.withLock { $0 += 1 }; return true })
        #expect(missing == .performDefaultHandling)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func theHookIsSetAndClearedGlobally() throws {
        defer { EngineTLS.serverTrustEvaluator = nil }
        #expect(EngineTLS.serverTrustEvaluator == nil)
        EngineTLS.serverTrustEvaluator = { host, _ in host == "nas.lan" }
        let trust = try makeTrust()
        let hook = try #require(EngineTLS.serverTrustEvaluator)
        #expect(hook("nas.lan", trust))
        #expect(!hook("elsewhere.example", trust))
        EngineTLS.serverTrustEvaluator = nil
        #expect(EngineTLS.serverTrustEvaluator == nil)
    }
}
