// Adapted from Pulse (https://github.com/Luraxx/pulse), Apache License 2.0. See NOTICE.
import Foundation
import CryptoKit

public struct GoogleOAuthConfig: Sendable {
    public var clientID: String

    public init(clientID: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// iOS OAuth clients redirect to the reversed client ID:
    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc"
    public var reversedClientScheme: String? {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return nil }
        let idPart = String(clientID.dropLast(suffix.count))
        return idPart.isEmpty ? nil : "com.googleusercontent.apps." + idPart
    }

    public var redirectURI: String? { reversedClientScheme.map { $0 + ":/oauth2redirect" } }
    public var isValid: Bool { reversedClientScheme != nil }
}

public enum HealthScopes {
    public static let read = [
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
    ]
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init() {
        var g = SystemRandomNumberGenerator()
        self.init(verifier: PKCE.base64URL(Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &g) })))
    }

    public init(verifier: String) {
        self.verifier = verifier
        challenge = PKCE.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct TokenSet: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiry: Date
    public var isExpiringSoon: Bool { expiry.timeIntervalSinceNow < 120 }
}

public enum AuthError: Error, LocalizedError, Sendable {
    case notConnected, invalidClientID, refreshExpired
    case exchangeFailed(String), network(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Google."
        case .invalidClientID: return "That doesn't look like an iOS client ID (…apps.googleusercontent.com)."
        case .refreshExpired: return "Google sign-in expired. Unverified (personal) Google apps expire after 7 days; tap Reconnect."
        case .exchangeFailed(let m): return "Token exchange failed: \(m)"
        case .network(let m): return "Network error: \(m)"
        }
    }
}

/// Authorization-code + PKCE flow (no client secret), tokens kept in the Keychain.
public final class GoogleAuth: @unchecked Sendable {
    static let service = "baseline.google.oauth"
    private let lock = NSLock()
    private var _tokens: TokenSet?

    public init() {
        if let data = Keychain.load(service: Self.service, account: "google"),
           let t = try? JSONDecoder().decode(TokenSet.self, from: data) {
            _tokens = t
        }
    }

    public var tokens: TokenSet? { lock.withLock { _tokens } }
    public var isConnected: Bool { tokens != nil }

    public func authorizationURL(config: GoogleOAuthConfig, pkce: PKCE, state: String) -> URL? {
        guard let redirect = config.redirectURI else { return nil }
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        c?.queryItems = [
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: HealthScopes.read.joined(separator: " ")),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        return c?.url
    }

    public static func extractCode(from url: URL, expectedState: String) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        return items.first(where: { $0.name == "code" })?.value
    }

    public func exchange(code: String, pkce: PKCE, config: GoogleOAuthConfig) async throws {
        guard let redirect = config.redirectURI else { throw AuthError.invalidClientID }
        let r = try await tokenRequest([
            "client_id": config.clientID, "code": code, "code_verifier": pkce.verifier,
            "grant_type": "authorization_code", "redirect_uri": redirect,
        ])
        store(TokenSet(accessToken: r.access_token, refreshToken: r.refresh_token,
                       expiry: Date().addingTimeInterval(r.expires_in ?? 3600)))
    }

    public func validAccessToken(config: GoogleOAuthConfig) async throws -> String {
        guard let t = tokens else { throw AuthError.notConnected }
        return t.isExpiringSoon ? try await refresh(config: config).accessToken : t.accessToken
    }

    @discardableResult
    public func refresh(config: GoogleOAuthConfig) async throws -> TokenSet {
        guard let t = tokens, let rt = t.refreshToken else { throw AuthError.refreshExpired }
        let r = try await tokenRequest(["client_id": config.clientID, "refresh_token": rt, "grant_type": "refresh_token"])
        let updated = TokenSet(accessToken: r.access_token, refreshToken: r.refresh_token ?? rt,
                               expiry: Date().addingTimeInterval(r.expires_in ?? 3600))
        store(updated)
        return updated
    }

    public func disconnect() {
        lock.withLock { _tokens = nil }
        Keychain.delete(service: Self.service, account: "google")
    }

    private func store(_ t: TokenSet) {
        lock.withLock { _tokens = t }
        if let data = try? JSONEncoder().encode(t) { Keychain.save(data, service: Self.service, account: "google") }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = params.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)

        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw AuthError.network(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("invalid_grant") { throw AuthError.refreshExpired }
            throw AuthError.exchangeFailed("HTTP \(status): \(body.prefix(300))")
        }
        do { return try JSONDecoder().decode(TokenResponse.self, from: data) } catch {
            throw AuthError.exchangeFailed("Unreadable response")
        }
    }
}

/// Minimal Keychain wrapper for tokens and the Claude API key.
public enum Keychain {
    @discardableResult
    public static func save(_ data: Data, service: String, account: String) -> Bool {
        delete(service: service, account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    public static func load(service: String, account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    @discardableResult
    public static func delete(service: String, account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(q as CFDictionary) == errSecSuccess
    }
}
