import Darwin
import Foundation
import Security

public enum TLSMode: String, Codable, CaseIterable, Sendable {
    case system = "System trust", custom = "Custom trust", insecure = "Insecure development"
}
public struct TLSProfile: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name = "New TLS profile"
    public var mode: TLSMode = .system
    public var includeSystemRoots = true
    public var anchors: [Data] = []
    public var requiresClientIdentity = false
    public var identityReference: Data?
    public var identityLabel: String?
    public init() {}
}
public enum TLSError: LocalizedError {
    case missingProfile, invalidCertificate, unavailableIdentity, importFailed, invalidProfile
    public var errorDescription: String? {
        switch self {
        case .missingProfile:
            "The selected TLS profile is missing. Select a profile or system defaults."
        case .invalidCertificate: "Select a valid DER or PEM certificate, at most 1 MiB."
        case .unavailableIdentity:
            "The selected client identity is missing, locked or inaccessible in Keychain. Select or import it again."
        case .importFailed:
            "The PKCS#12 identity could not be imported. Check the file, password and Keychain permissions."
        case .invalidProfile:
            "Custom trust needs at least one valid certificate; TLS profile names cannot be empty."
        }
    }
}
public struct TLSIdentityChoice: Identifiable, Sendable {
    public var id: Data { reference }
    public let reference: Data
    public let label: String
}
public protocol TLSIdentityProvider: Sendable {
    func identity(for reference: Data) throws -> SecIdentity
}
public struct SystemTLSIdentities: TLSIdentityProvider {
    public init() {}
    public func identity(for reference: Data) throws -> SecIdentity {
        var item: CFTypeRef?
        guard
            SecItemCopyMatching(
                [
                    kSecClass: kSecClassIdentity, kSecValuePersistentRef: reference,
                    kSecReturnRef: true,
                ] as CFDictionary, &item) == errSecSuccess,
            let item, CFGetTypeID(item) == SecIdentityGetTypeID()
        else { throw TLSError.unavailableIdentity }
        return (item as! SecIdentity)
    }
}
public enum TLSProfiles {
    public static func selected(
        _ id: UUID?, from profiles: [TLSProfile], fileIdentityAvailable: Bool = false
    ) throws -> TLSProfile? {
        guard let id else { return nil }
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw TLSError.missingProfile
        }
        try validate(profile, requireUsable: true)
        if profile.requiresClientIdentity && profile.identityReference == nil
            && !fileIdentityAvailable
        {
            throw TLSError.unavailableIdentity
        }
        return profile
    }
    public static func validate(_ profile: TLSProfile, requireUsable: Bool = false) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            profile.anchors.count <= 16,
            !requireUsable || profile.mode != .custom || !profile.anchors.isEmpty
        else { throw TLSError.invalidProfile }
        for data in profile.anchors {
            guard data.count <= 1024 * 1024,
                SecCertificateCreateWithData(nil, data as CFData) != nil
            else { throw TLSError.invalidCertificate }
        }
        guard (profile.identityReference?.count ?? 0) <= 64 * 1024 else {
            throw TLSError.invalidProfile
        }
    }
    public static func certificateData(_ data: Data) throws -> Data {
        guard data.count <= 1024 * 1024 else { throw TLSError.invalidCertificate }
        let decoded: Data
        if let text = String(data: data, encoding: .utf8),
            text.contains("-----BEGIN CERTIFICATE-----")
        {
            let chunks = text.components(separatedBy: "-----BEGIN CERTIFICATE-----")
            guard chunks.count == 2, let end = chunks[1].range(of: "-----END CERTIFICATE-----"),
                let raw = Data(
                    base64Encoded: String(chunks[1][..<end.lowerBound]),
                    options: .ignoreUnknownCharacters)
            else { throw TLSError.invalidCertificate }
            decoded = raw
        } else {
            decoded = data
        }
        guard SecCertificateCreateWithData(nil, decoded as CFData) != nil else {
            throw TLSError.invalidCertificate
        }
        return decoded
    }
    public static func readFile(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = Darwin.open(
            url.standardizedFileURL.resolvingSymlinksInPath().path,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw TLSError.invalidCertificate }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size <= maximum
        else { throw TLSError.invalidCertificate }
        var data = Data()
        while let chunk = try input.read(upToCount: min(65536, maximum + 1 - data.count)),
            !chunk.isEmpty
        {
            data.append(chunk)
            guard data.count <= maximum else { throw TLSError.invalidCertificate }
        }
        return data
    }
    static func evaluate(_ trust: SecTrust, host: String, profile: TLSProfile) -> Bool {
        guard
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess
        else { return false }
        let certificates = profile.anchors.compactMap {
            SecCertificateCreateWithData(nil, $0 as CFData)
        }
        guard certificates.count == profile.anchors.count,
            SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess,
            SecTrustSetAnchorCertificatesOnly(trust, !profile.includeSystemRoots) == errSecSuccess
        else { return false }
        SecTrustSetNetworkFetchAllowed(trust, false)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
public actor TLSIdentityManager {
    public init() {}
    public func choices() throws -> [TLSIdentityChoice] {
        var items: CFTypeRef?
        let status = SecItemCopyMatching(
            [kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]
                as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let identities = items as? [SecIdentity] else {
            throw TLSError.unavailableIdentity
        }
        return try identities.map(Self.choice)
    }
    private static func choice(_ identity: SecIdentity) throws -> TLSIdentityChoice {
        var item: CFTypeRef?
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
            SecItemCopyMatching(
                [
                    kSecClass: kSecClassIdentity, kSecValueRef: identity,
                    kSecReturnPersistentRef: true,
                ] as CFDictionary, &item) == errSecSuccess,
            let reference = item as? Data
        else { throw TLSError.unavailableIdentity }
        return TLSIdentityChoice(
            reference: reference,
            label: SecCertificateCopySubjectSummary(certificate) as String? ?? "Client identity")
    }
    public func importPKCS12(_ data: Data, passphrase: String) throws -> [TLSIdentityChoice] {
        guard data.count <= 4 * 1024 * 1024 else { throw TLSError.importFailed }
        var items: CFArray?
        // This explicit user action imports into the default macOS Keychain.
        guard
            SecPKCS12Import(
                data as CFData, [kSecImportExportPassphrase: passphrase] as CFDictionary, &items)
                == errSecSuccess,
            let values = items as? [[String: Any]]
        else { throw TLSError.importFailed }
        return try values.compactMap { $0[kSecImportItemIdentity as String] as! SecIdentity? }.map(
            Self.choice)
    }
}
