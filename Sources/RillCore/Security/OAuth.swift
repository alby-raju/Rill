import Foundation
import CryptoKit
import Security
import CoreFoundation

public struct OAuthConfiguration: Codable, Equatable, Sendable {
    public var authorizationEndpoint = ""
    public var tokenEndpoint = ""
    public var clientID = ""
    public var clientSecretName = ""
    public var scope = ""
    public var clientAuthentication: OAuthClientAuthentication = .none
    public init() {}
}
public enum OAuthClientAuthentication: String, Codable, CaseIterable, Sendable { case none = "Public client", basic = "Client secret: Basic", body = "Client secret: POST body" }
public enum OAuthError: LocalizedError, Equatable {
    case invalidConfiguration, invalidCallback, denied, invalidResponse, tokenRejected, responseTooLarge, timedOut
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Check OAuth endpoints, client ID and client-secret reference. HTTPS is required except literal loopback test endpoints."
        case .invalidCallback: "OAuth callback state, path or parameters did not match this authorization session."
        case .denied: "Authorization was denied by the provider."
        case .invalidResponse: "The token endpoint returned an invalid or unsupported bearer-token response."
        case .tokenRejected: "The token endpoint rejected the request. Check client configuration and scope. Response content is not logged."
        case .responseTooLarge: "The token endpoint response exceeds 64 KiB."
        case .timedOut: "OAuth authorization timed out. Start a new session to retry."
        }
    }
}
public struct OAuthToken: Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let scope: String?
}
public struct PKCEChallenge: Sendable {
    public let verifier: String
    public let state: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public init() throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OAuthError.invalidConfiguration }
            return Self.base64URL(Data(bytes))
        }
        verifier = try random(); state = try random()
    }
    init(verifier: String, state: String) { self.verifier = verifier; self.state = state }
    private static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
public enum OAuthClient {
    static func endpoint(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value), let host = components.host, !host.isEmpty, components.user == nil, components.password == nil, components.fragment == nil,
              components.scheme == "https" || (components.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host)), let url = components.url else { throw OAuthError.invalidConfiguration }
        return url
    }
    public static func authorizationURL(configuration: OAuthConfiguration, redirect: URL, pkce: PKCEChallenge) throws -> URL {
        let url = try endpoint(configuration.authorizationEndpoint)
        guard !configuration.clientID.isEmpty, redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.port != nil else { throw OAuthError.invalidConfiguration }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let reserved: Set<String> = ["response_type", "client_id", "redirect_uri", "scope", "state", "code_challenge", "code_challenge_method"]
        var query = (components.queryItems ?? []).filter { !reserved.contains($0.name) }
        query += [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: configuration.clientID), URLQueryItem(name: "redirect_uri", value: redirect.absoluteString), URLQueryItem(name: "state", value: pkce.state), URLQueryItem(name: "code_challenge", value: pkce.challenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        if !configuration.scope.isEmpty { query.append(URLQueryItem(name: "scope", value: configuration.scope)) }
        components.percentEncodedQuery = query.map { HTTPEncoding.component($0.name) + "=" + HTTPEncoding.component($0.value ?? "") }.joined(separator: "&")
        return components.url!
    }
    public static func callbackCode(target: String, redirect: URL, expectedState: String) throws -> String {
        guard target.utf8.count <= 8192, target.hasPrefix("/"), !target.hasPrefix("//"), let components = URLComponents(string: target), components.path == redirect.path, components.fragment == nil else { throw OAuthError.invalidCallback }
        var decoded = components
        decoded.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let items = decoded.queryItems ?? []
        func single(_ name: String) throws -> String? {
            let matches = items.filter { $0.name == name }
            guard matches.count <= 1 else { throw OAuthError.invalidCallback }
            return matches.first?.value
        }
        guard try single("state") == expectedState else { throw OAuthError.invalidCallback }
        if try single("error") != nil { throw OAuthError.denied }
        guard let code = try single("code"), !code.isEmpty, code.utf8.count <= 4096 else { throw OAuthError.invalidCallback }
        return code
    }
    public static func tokenRequest(configuration: OAuthConfiguration, secret: String?, code: String? = nil, redirect: URL? = nil, verifier: String? = nil) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(configuration.tokenEndpoint)); request.httpMethod = "POST"; request.timeoutInterval = 30
        guard !configuration.clientID.isEmpty else { throw OAuthError.invalidConfiguration }
        if code == nil && configuration.clientAuthentication == .none { throw OAuthError.invalidConfiguration }
        var fields = [("grant_type", code == nil ? "client_credentials" : "authorization_code")]
        if let code {
            guard !code.isEmpty, let redirect, let verifier, (43...128).contains(verifier.utf8.count), verifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~").contains($0) }) else { throw OAuthError.invalidConfiguration }
            fields += [("code", code), ("redirect_uri", redirect.absoluteString), ("code_verifier", verifier)]
        } else if !configuration.scope.isEmpty { fields.append(("scope", configuration.scope)) }
        switch configuration.clientAuthentication {
        case .none: fields.append(("client_id", configuration.clientID))
        case .basic:
            guard let secret, !secret.isEmpty else { throw OAuthError.invalidConfiguration }
            let value = HTTPEncoding.formComponent(configuration.clientID) + ":" + HTTPEncoding.formComponent(secret)
            request.setValue("Basic " + Data(value.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        case .body:
            guard let secret, !secret.isEmpty else { throw OAuthError.invalidConfiguration }
            fields += [("client_id", configuration.clientID), ("client_secret", secret)]
        }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = Data(fields.map { HTTPEncoding.formComponent($0.0) + "=" + HTTPEncoding.formComponent($0.1) }.joined(separator: "&").utf8)
        guard data.count <= 1024 * 1024 else { throw OAuthError.invalidConfiguration }
        request.httpBody = data; return request
    }
    public static func decodeToken(_ data: Data, status: Int, now: Date = Date()) throws -> OAuthToken {
        guard data.count <= 64 * 1024 else { throw OAuthError.responseTooLarge }
        guard (200...299).contains(status) else { throw OAuthError.tokenRejected }
        let value: [String: Any]
        do { try WorkspaceFile.checkJSONBounds(data); value = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] } catch { throw OAuthError.invalidResponse }
        guard value["error"] == nil, let token = value["access_token"] as? String, !token.isEmpty,
              let type = value["token_type"] as? String, type.lowercased() == "bearer",
              !token.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else { throw OAuthError.invalidResponse }
        var expiration: Date?
        if let raw = value["expires_in"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 10 * 365 * 24 * 3600 else { throw OAuthError.invalidResponse }
            expiration = now.addingTimeInterval(number.doubleValue)
        }
        return OAuthToken(accessToken: token, expiresAt: expiration, scope: value["scope"] as? String)
    }
    public static func acquire(configuration: OAuthConfiguration, secrets: NamedSecretResolver, code: String? = nil, redirect: URL? = nil, verifier: String? = nil) async throws -> OAuthToken {
        let secret = configuration.clientAuthentication == .none ? nil : try secrets.resolve(configuration.clientSecretName)
        let request = try tokenRequest(configuration: configuration, secret: secret, code: code, redirect: redirect, verifier: verifier)
        return try await acquire(request)
    }
    public static func acquire(_ request: URLRequest) async throws -> OAuthToken {
        try Task.checkCancellation()
        let configuration = HTTPClientConfiguration.make()
        let session = URLSession(configuration: configuration, delegate: OAuthNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw OAuthError.invalidResponse }
        guard response.expectedContentLength <= 64 * 1024 else { throw OAuthError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 64 * 1024 { throw OAuthError.responseTooLarge }
            if data.count % 1024 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return try decodeToken(data, status: response.statusCode)
    }
}
private final class OAuthNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
