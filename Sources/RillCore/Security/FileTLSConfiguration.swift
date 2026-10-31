import Foundation
import Security

public enum FileTLSError: Error {
    case invalidOptions, invalidCertificate, invalidIdentity, invalidPassphrase, invalidOrigin
}

/// Immutable Security objects are retained only in this process. No Keychain imports or lookups.
public final class FileTLSConfiguration: @unchecked Sendable {
    public let profile: TLSProfile
    public let overridesTrust: Bool
    public var hasClientIdentity: Bool { identity != nil }
    private let identity: SecIdentity?
    private let chain: [SecCertificate]
    private let clientOrigin: HTTPSOrigin?

    public init(
        caCertificates: Data? = nil, clientCertificate: Data? = nil, clientKey: Data? = nil,
        pkcs12: Data? = nil, passphrase: String = "", clientOrigin: String? = nil,
        insecure: Bool = false, includeSystemRoots: Bool = false
    ) throws {
        try Task.checkCancellation()
        let hasPEM = clientCertificate != nil || clientKey != nil
        let hasIdentity = hasPEM || pkcs12 != nil
        guard (clientCertificate == nil) == (clientKey == nil),
            pkcs12 == nil || !hasPEM, hasIdentity == (clientOrigin != nil),
            passphrase.isEmpty || pkcs12 != nil,
            !insecure || caCertificates == nil,
            !includeSystemRoots || caCertificates != nil
        else { throw FileTLSError.invalidOptions }
        guard passphrase.utf8.count <= 4096, !passphrase.contains("\0") else {
            throw FileTLSError.invalidPassphrase
        }
        var profile = TLSProfile()
        profile.name = "File-run TLS"
        if let caCertificates {
            profile.mode = .custom
            profile.anchors = try Self.certificates(caCertificates).map {
                SecCertificateCopyData($0) as Data
            }
            profile.includeSystemRoots = includeSystemRoots
        } else if insecure {
            profile.mode = .insecure
        }
        self.profile = profile
        overridesTrust = caCertificates != nil || insecure
        self.clientOrigin = try clientOrigin.map(HTTPSOrigin.init)
        if let pkcs12 {
            guard pkcs12.count <= 4 * 1024 * 1024 else { throw FileTLSError.invalidIdentity }
            var items: CFArray?
            // macOS 15+: never omit this option or fall back to the default Keychain import.
            guard
                SecPKCS12Import(
                    pkcs12 as CFData,
                    [kSecImportExportPassphrase: passphrase, kSecImportToMemoryOnly: true]
                        as CFDictionary,
                    &items) == errSecSuccess,
                let entries = items as? [[String: Any]]
            else { throw FileTLSError.invalidIdentity }
            let identities = entries.compactMap { $0[kSecImportItemIdentity as String] }
            guard identities.count == 1, let raw = identities.first,
                CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID(),
                let entry = entries.first(where: { $0[kSecImportItemIdentity as String] != nil })
            else { throw FileTLSError.invalidIdentity }
            // CoreFoundation bridging follows an explicit runtime type check above.
            let identity = raw as! SecIdentity
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                let certificate
            else {
                throw FileTLSError.invalidIdentity
            }
            var key: SecKey?
            guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else {
                throw FileTLSError.invalidIdentity
            }
            try Self.validateKeyPair(certificate, privateKey: key)
            try Self.validateClientCertificate(certificate)
            let objects = entry[kSecImportItemCertChain as String] as? [Any] ?? []
            guard objects.count <= 16 else { throw FileTLSError.invalidIdentity }
            var chain: [SecCertificate] = []
            for object in objects {
                guard CFGetTypeID(object as CFTypeRef) == SecCertificateGetTypeID() else {
                    throw FileTLSError.invalidIdentity
                }
                let candidate = object as! SecCertificate
                if SecCertificateCopyData(candidate) as Data != SecCertificateCopyData(certificate)
                    as Data
                {
                    chain.append(candidate)
                }
            }
            self.identity = identity
            self.chain = chain
        } else if let clientCertificate, let clientKey {
            let certificates = try Self.certificates(clientCertificate)
            guard let certificate = certificates.first, clientKey.count <= 1024 * 1024,
                let text = String(data: clientKey, encoding: .utf8),
                !text.contains("Proc-Type:"),
                !text.contains("DEK-Info:")
            else { throw FileTLSError.invalidIdentity }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let labels = ["PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"]
            guard
                let label = labels.first(where: { trimmed.hasPrefix("-----BEGIN " + $0 + "-----") }
                ),
                trimmed.hasSuffix("-----END " + label + "-----"),
                trimmed.components(separatedBy: "-----BEGIN ").count == 2
            else { throw FileTLSError.invalidIdentity }
            var format = SecExternalFormat.formatUnknown
            var type = SecExternalItemType.itemTypePrivateKey
            var parameters = SecItemImportExportKeyParameters()
            let empty = "" as CFString
            parameters.passphrase = Unmanaged.passUnretained(empty)
            var items: CFArray?
            let status = withExtendedLifetime(empty) {
                SecItemImport(
                    clientKey as CFData, "pem" as CFString, &format, &type, [],
                    &parameters, nil, &items)
            }
            guard status == errSecSuccess, type == .itemTypePrivateKey,
                let objects = items as? [Any], objects.count == 1, let raw = objects.first,
                CFGetTypeID(raw as CFTypeRef) == SecKeyGetTypeID()
            else { throw FileTLSError.invalidIdentity }
            let key = raw as! SecKey
            try Self.validateKeyPair(certificate, privateKey: key)
            guard let identity = SecIdentityCreate(nil, certificate, key) else {
                throw FileTLSError.invalidIdentity
            }
            try Self.validateClientCertificate(certificate)
            self.identity = identity
            self.chain = Array(certificates.dropFirst())
        } else {
            identity = nil
            chain = []
        }
    }

    static func validateKeyPair(_ certificate: SecCertificate, privateKey: SecKey) throws {
        // Identity construction alone accepts mismatched keys on some supported macOS versions.
        // Compare only public material; never export the private key to check the pair.
        guard let certificateKey = SecCertificateCopyKey(certificate),
            let publicKey = SecKeyCopyPublicKey(privateKey),
            let certificateBytes = SecKeyCopyExternalRepresentation(certificateKey, nil),
            let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil),
            certificateBytes as Data == publicBytes as Data
        else { throw FileTLSError.invalidIdentity }
    }

    static func certificates(_ data: Data) throws -> [SecCertificate] {
        guard !data.isEmpty, data.count <= 1024 * 1024 else {
            throw FileTLSError.invalidCertificate
        }
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        if var text = String(data: data, encoding: .utf8), text.contains(begin) {
            var certificates: [SecCertificate] = []
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            while !text.isEmpty {
                try Task.checkCancellation()
                guard text.hasPrefix(begin), let boundary = text.range(of: end),
                    certificates.count < 16
                else {
                    throw FileTLSError.invalidCertificate
                }
                let base64 = text[
                    text.index(text.startIndex, offsetBy: begin.count)..<boundary.lowerBound
                ]
                .filter { !$0.isWhitespace }
                guard let der = Data(base64Encoded: String(base64)),
                    let certificate = SecCertificateCreateWithData(nil, der as CFData)
                else { throw FileTLSError.invalidCertificate }
                certificates.append(certificate)
                text = String(text[boundary.upperBound...]).trimmingCharacters(
                    in: .whitespacesAndNewlines)
            }
            return certificates
        }
        guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
            throw FileTLSError.invalidCertificate
        }
        return [certificate]
    }

    static func validateClientCertificate(_ certificate: SecCertificate, now: Date = Date()) throws
    {
        guard let before = SecCertificateCopyNotValidBeforeDate(certificate),
            let after = SecCertificateCopyNotValidAfterDate(certificate),
            CFDateGetAbsoluteTime(before) <= now.timeIntervalSinceReferenceDate,
            CFDateGetAbsoluteTime(after) > now.timeIntervalSinceReferenceDate
        else { throw FileTLSError.invalidIdentity }
    }

    func credential(for url: URL?) -> (SecIdentity, [SecCertificate])? {
        guard let url, let origin = HTTPSOrigin(url: url), origin == clientOrigin, let identity
        else { return nil }
        return (identity, chain)
    }

    static func matches(_ space: URLProtectionSpace, url: URL?) -> Bool {
        guard !space.isProxy(), space.protocol?.lowercased() == "https", let url,
            let origin = HTTPSOrigin(url: url)
        else { return false }
        return origin.host == HTTPSOrigin.host(space.host) && origin.port == space.port
    }
}

private struct HTTPSOrigin: Equatable, Sendable {
    let host: String
    let port: Int
    static func host(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }
    init(_ text: String) throws {
        guard text.utf8.count <= 4096, let parts = URLComponents(string: text),
            parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil,
            parts.user == nil, parts.password == nil, let url = parts.url,
            let origin = Self(url: url)
        else { throw FileTLSError.invalidOrigin }
        self = origin
    }
    init?(url: URL) {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil, (1...65535).contains(url.port ?? 443)
        else { return nil }
        let normalized = Self.host(host)
        guard !normalized.isEmpty else { return nil }
        self.host = normalized
        port = url.port ?? 443
    }
}
