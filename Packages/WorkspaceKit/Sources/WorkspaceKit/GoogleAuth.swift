import Foundation
import Security

public enum WorkspaceKitError: LocalizedError, Equatable {
    case credentialsNotFound(String)
    case unsupportedCredentials(String)
    case invalidPrivateKey
    case http(service: String, status: Int, message: String)
    case clusterNotFound(String)
    case notAWorkspace(String)
    case timedOut(String)
    case podUnhealthy(pod: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .credentialsNotFound(let path): "No Google credentials at \(path). Run `gcloud auth application-default login` once, or choose a service-account key."
        case .unsupportedCredentials(let type): "Unsupported Google credentials type \"\(type)\"."
        case .invalidPrivateKey: "The service-account private key could not be read."
        case .http(let service, 401, _): "\(service) rejected the Google credentials (401). Sign in again."
        case .http(let service, 403, let message): "\(service) denied access (403): \(message)"
        case .http(let service, let status, let message): "\(service) error \(status): \(message)"
        case .clusterNotFound(let name): "Cluster \(name) was not found or is not reachable."
        case .notAWorkspace(let name): "\(name) is not a workspace."
        case .timedOut(let what): "Timed out waiting for \(what)."
        case .podUnhealthy(let pod, let reason): "Pod \(pod) is in \(reason) state."
        }
    }
}

/// Supplies OAuth access tokens for Google APIs (and GKE, which accepts them).
public protocol GoogleTokenSource: Sendable {
    func accessToken() async throws -> String
}

/// Application Default Credentials read in-process: no gcloud or auth plugin is executed.
///
/// Supports the two file formats `gcloud` writes:
/// - `authorized_user` (`gcloud auth application-default login`): refresh-token grant;
/// - `service_account` (a JSON key): a JWT signed locally with RS256, exchanged for a token.
public actor GoogleCredentials: GoogleTokenSource {
    public static let cloudPlatformScope = "https://www.googleapis.com/auth/cloud-platform"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// `$GOOGLE_APPLICATION_CREDENTIALS`, else `~/.config/gcloud/application_default_credentials.json`.
    public static var defaultPath: URL {
        if let path = ProcessInfo.processInfo.environment["GOOGLE_APPLICATION_CREDENTIALS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/gcloud/application_default_credentials.json")
    }

    enum Kind {
        case authorizedUser(clientID: String, clientSecret: String, refreshToken: String)
        case serviceAccount(email: String, privateKey: SecKey, tokenURI: URL)
    }

    let kind: Kind
    /// The service-account email, when known.
    public nonisolated let account: String?
    private let session: URLSession
    private var cached: (token: String, expiry: Date)?

    public init(file: URL = GoogleCredentials.defaultPath, session: URLSession = .shared) throws {
        guard let data = try? Data(contentsOf: file) else { throw WorkspaceKitError.credentialsNotFound(file.path) }
        try self.init(json: JSON.parse(String(decoding: data, as: UTF8.self)), session: session)
    }

    public init(json: JSON, session: URLSession = .shared) throws {
        self.session = session
        switch json["type"]?.string {
        case "authorized_user":
            guard let id = json["client_id"]?.string, let secret = json["client_secret"]?.string, let refresh = json["refresh_token"]?.string else {
                throw WorkspaceKitError.unsupportedCredentials("authorized_user without client_id/client_secret/refresh_token")
            }
            kind = .authorizedUser(clientID: id, clientSecret: secret, refreshToken: refresh)
            account = nil
        case "service_account":
            guard let email = json["client_email"]?.string, let pem = json["private_key"]?.string else {
                throw WorkspaceKitError.unsupportedCredentials("service_account without client_email/private_key")
            }
            kind = .serviceAccount(
                email: email, privateKey: try RSAKey.privateKey(pem: pem),
                tokenURI: json["token_uri"]?.string.flatMap(URL.init(string:)) ?? Self.tokenURL)
            account = email
        default:
            throw WorkspaceKitError.unsupportedCredentials(json["type"]?.string ?? "missing")
        }
    }

    public func accessToken() async throws -> String {
        if let cached, cached.expiry > Date().addingTimeInterval(60) { return cached.token }
        var request: URLRequest
        switch kind {
        case .authorizedUser(let id, let secret, let refresh):
            request = URLRequest(url: Self.tokenURL)
            request.httpBody = Self.form([
                "grant_type": "refresh_token", "client_id": id, "client_secret": secret, "refresh_token": refresh,
            ])
        case .serviceAccount(let email, let key, let tokenURI):
            request = URLRequest(url: tokenURI)
            let assertion = try JWT.sign(
                claims: ["iss": .string(email), "scope": .string(Self.cloudPlatformScope), "aud": .string(tokenURI.absoluteString)],
                key: key)
            request.httpBody = Self.form(["grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion])
        }
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        let json = try JSON.parse(String(decoding: data, as: UTF8.self))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let token = json["access_token"]?.string else {
            throw WorkspaceKitError.http(service: "Google OAuth", status: status,
                                         message: json["error_description"]?.string ?? json["error"]?.string ?? "no access_token")
        }
        cached = (token, Date().addingTimeInterval(json["expires_in"]?.double ?? 3600))
        return token
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

/// A fixed token, for tests or tokens obtained elsewhere.
public struct StaticToken: GoogleTokenSource {
    let token: String
    public init(_ token: String) { self.token = token }
    public func accessToken() async throws -> String { token }
}

enum JWT {
    static func sign(claims: [String: JSON], key: SecKey, now: Date = Date()) throws -> String {
        var payload = claims
        let issued = Int(now.timeIntervalSince1970)
        payload["iat"] = .number(Double(issued))
        payload["exp"] = .number(Double(issued + 3600))
        let header: JSON = ["alg": "RS256", "typ": "JWT"]
        let input = base64URL(Data(header.line.utf8)) + "." + base64URL(Data(JSON.object(payload).line.utf8))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error) as Data? else {
            throw WorkspaceKitError.invalidPrivateKey
        }
        return input + "." + base64URL(signature)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum RSAKey {
    /// Reads a PKCS#8 ("BEGIN PRIVATE KEY", as in Google key files) or PKCS#1 PEM RSA key.
    static func privateKey(pem: String) throws -> SecKey {
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw WorkspaceKitError.invalidPrivateKey }
        let pkcs1 = pem.contains("BEGIN RSA PRIVATE KEY") ? der : try unwrapPKCS8(der)
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else { throw WorkspaceKitError.invalidPrivateKey }
        return key
    }

    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
    static func unwrapPKCS8(_ der: Data) throws -> Data {
        var reader = DERReader(bytes: [UInt8](der))
        let outer = try reader.element(tag: 0x30)
        var inner = DERReader(bytes: outer)
        _ = try inner.element(tag: 0x02)
        _ = try inner.element(tag: 0x30)
        return Data(try inner.element(tag: 0x04))
    }

    struct DERReader {
        let bytes: [UInt8]
        var offset = 0

        mutating func element(tag: UInt8) throws -> [UInt8] {
            guard offset < bytes.count, bytes[offset] == tag else { throw WorkspaceKitError.invalidPrivateKey }
            offset += 1
            guard offset < bytes.count else { throw WorkspaceKitError.invalidPrivateKey }
            var length = Int(bytes[offset])
            offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard count <= 4, offset + count <= bytes.count else { throw WorkspaceKitError.invalidPrivateKey }
                length = bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
                offset += count
            }
            guard offset + length <= bytes.count else { throw WorkspaceKitError.invalidPrivateKey }
            defer { offset += length }
            return Array(bytes[offset..<offset + length])
        }
    }
}
