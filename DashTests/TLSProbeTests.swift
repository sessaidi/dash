import Foundation
import Security
import Testing

/// Opt-in (DASH_TLS_PROBE=<host>, DASH_TLS_CA=<pem path>): the same request a plugin makes, from the app process.
struct TLSProbeTests {
    final class Delegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let anchor: SecCertificate
        var log: [String] = []
        init(anchor: SecCertificate) { self.anchor = anchor }
        func urlSession(_ s: URLSession, didReceive c: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            log.append("challenge \(c.protectionSpace.authenticationMethod)")
            guard c.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = c.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, c.protectionSpace.host as CFString))
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            var error: CFError?
            let ok = SecTrustEvaluateWithError(trust, &error)
            log.append("trust \(ok) \(error.map { CFErrorCopyDescription($0) as String } ?? "")")
            return ok ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_TLS_PROBE"] != nil))
    func probe() async throws {
        let env = ProcessInfo.processInfo.environment
        let pem = try String(contentsOfFile: env["DASH_TLS_CA"]!, encoding: .utf8)
        let der = Data(base64Encoded: pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined())!
        let delegate = Delegate(anchor: SecCertificateCreateWithData(nil, der as CFData)!)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        do {
            let (_, response) = try await session.data(from: URL(string: "https://\(env["DASH_TLS_PROBE"]!)/version")!)
            print("TLSPROBE status \((response as? HTTPURLResponse)?.statusCode ?? 0) \(delegate.log)")
        } catch {
            print("TLSPROBE error \((error as NSError).code) \((error as NSError).userInfo[NSUnderlyingErrorKey] ?? "") \(delegate.log)")
        }
    }
}
