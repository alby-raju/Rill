import Foundation

public enum AuthenticationError: LocalizedError {
    case missingProfile, invalidName, missingSecret, readOnlyProvider
    public var errorDescription: String? {
        switch self {
        case .missingProfile: "The selected authentication profile is missing. Select another profile or choose request-specific auth."
        case .invalidName: "Secret names must be 1–128 ASCII letters, digits, dots, hyphens or underscores."
        case .missingSecret: "The referenced secret is missing or empty. Update the native secret or the RILL_SECRET_ process provider."
        case .readOnlyProvider: "Process-environment secrets are read-only. Change them before starting Rill."
        }
    }
}
public struct NamedSecret: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public init(name: String) { self.name = name }
}
public struct AuthenticationProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = "New profile"
    public var kind: AuthKind = .bearer
    public var username = ""
    public var secretName = ""
    public var apiKeyName = ""
    public var apiKeyLocation: APIKeyLocation = .header
    public init() {}
}
public enum AuthenticationProfiles {
    public static func applying(to draft: RequestDraft, profiles: [AuthenticationProfile]) throws -> RequestDraft {
        guard let id = draft.authProfileID else { return draft }
        guard let profile = profiles.first(where: { $0.id == id }) else { throw AuthenticationError.missingProfile }
        var result = draft
        result.authProfileID = nil
        result.auth = profile.kind; result.username = profile.username
        result.apiKeyName = profile.apiKeyName; result.apiKeyLocation = profile.apiKeyLocation
        if profile.kind == .none { result.credential = "" }
        else {
            try NamedSecretResolver.validateName(profile.secretName)
            result.credential = "{{secret:" + profile.secretName + "}}"
        }
        return result
    }
}

private final class SecretValueCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func value(_ name: String, load: () throws -> String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = values[name] { return value }
        let value = try load(); values[name] = value; return value
    }
}
public struct NamedSecretResolver: Sendable {
    public let catalog: [NamedSecret]
    private let credentials: any CredentialStore
    private let processEnvironment: [String: String]
    private let cache = SecretValueCache()
    public init(catalog: [NamedSecret], credentials: any CredentialStore = KeychainCredentialStore(service: "app.rill.namedsecrets"), processEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.catalog = catalog; self.credentials = credentials; self.processEnvironment = processEnvironment
    }
    public static func validateName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard (1...128).contains(name.utf8.count), name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw AuthenticationError.invalidName }
    }
    public static func environmentKey(for name: String) throws -> String {
        try validateName(name)
        return "RILL_SECRET_" + name.uppercased().replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_")
    }
    public func resolve(_ name: String) throws -> String {
        try Self.validateName(name)
        return try cache.value(name) {
        let value: String
        if let native = catalog.first(where: { $0.name == name }) {
            // Present native metadata owns this name. Denied/deleted keys never fall back.
            value = try credentials.read(native.id)
        } else { value = processEnvironment[try Self.environmentKey(for: name)] ?? "" }
        guard !value.isEmpty else { throw AuthenticationError.missingSecret }
        guard value.utf8.count <= 1024 * 1024 else { throw EditingError.expansionLimit }
        return value
        }
    }
}

public actor NamedSecretVault {
    private let credentials: any CredentialStore
    public init(credentials: any CredentialStore = KeychainCredentialStore(service: "app.rill.namedsecrets")) { self.credentials = credentials }
    public func set(_ value: String, for secret: NamedSecret) throws {
        try NamedSecretResolver.validateName(secret.name)
        guard !value.isEmpty else { throw AuthenticationError.missingSecret }
        guard value.utf8.count <= 1024 * 1024 else { throw EditingError.expansionLimit }
        try credentials.write(value, id: secret.id)
    }
    public func delete(_ secret: NamedSecret) throws { try credentials.write("", id: secret.id) }
}
