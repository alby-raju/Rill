import Foundation
import RillCore

struct FileTLSOptions {
    private static let identityInputs = [
        "ssl-client-cert", "ssl-client-key", "ssl-client-p12", "ssl-passphrase-file",
    ]
    static let inputNames = ["ca-cert", "ssl-client-map"] + identityInputs
    static let values = Set(inputNames + ["ssl-client-origin"])
    static let flags: Set<String> = ["insecure", "include-system-roots"]

    private struct IdentityFiles {
        let origin: String?
        let certificate: URL?
        let key: URL?
        let pkcs12: URL?
        let passphraseFile: URL?

        var inputs: [URL] { [certificate, key, pkcs12, passphraseFile].compactMap { $0 } }

        func configuration(
            ca: Data? = nil, insecure: Bool = false, includeSystemRoots: Bool = false
        ) throws -> FileTLSConfiguration {
            guard passphraseFile == nil || pkcs12 != nil || key != nil else {
                throw CLIError.usage(
                    "A passphrase file requires an encrypted PEM key or a PKCS#12 identity. No requests sent."
                )
            }
            return try FileTLSConfiguration(
                caCertificates: ca,
                clientCertificate: certificate.map {
                    try BoundedFileInput.read($0, limit: 1024 * 1024)
                },
                clientKey: key.map { try BoundedFileInput.read($0, limit: 1024 * 1024) },
                pkcs12: pkcs12.map { try BoundedFileInput.read($0, limit: 4 * 1024 * 1024) },
                passphrase: passphraseFile.map(FileTLSOptions.readPassphrase),
                clientOrigin: origin, insecure: insecure, includeSystemRoots: includeSystemRoots)
        }
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let identities: [[String: String]]
    }

    private let mappedIdentities: [IdentityFiles]

    init(_ args: Arguments) throws {
        guard let path = args.value("ssl-client-map") else {
            mappedIdentities = []
            return
        }
        guard Set(Self.identityInputs + ["ssl-client-origin"]).isDisjoint(with: args.values.keys)
        else {
            throw CLIError.usage(
                "Choose --ssl-client-map or the single-identity TLS options. No requests sent.")
        }
        let manifest = URL(fileURLWithPath: path).standardizedFileURL
        do {
            let data = try BoundedFileInput.read(manifest, limit: 64 * 1024)
            try WorkspaceFile.checkJSONBounds(data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys) == ["schemaVersion", "identities"]
            else { throw FileTLSError.invalidOptions }
            let map = try JSONDecoder().decode(Manifest.self, from: data)
            guard map.schemaVersion == 1,
                (1...FileTLSConfiguration.maximumClientIdentities).contains(map.identities.count)
            else { throw FileTLSError.invalidOptions }
            let directory = manifest.deletingLastPathComponent()
            mappedIdentities = try map.identities.map { entry in
                let keys = Set(entry.keys)
                guard let origin = entry["origin"],
                    keys == ["origin", "certificate", "key"]
                        || keys == ["origin", "certificate", "key", "passphraseFile"]
                        || keys == ["origin", "pkcs12"]
                        || keys == ["origin", "pkcs12", "passphraseFile"]
                else { throw FileTLSError.invalidOptions }
                func file(_ name: String) throws -> URL? {
                    guard let path = entry[name] else { return nil }
                    guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0") else {
                        throw FileTLSError.invalidOptions
                    }
                    return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
                }
                return try IdentityFiles(
                    origin: origin, certificate: file("certificate"), key: file("key"),
                    pkcs12: file("pkcs12"), passphraseFile: file("passphraseFile"))
            }
        } catch is CancellationError { throw CancellationError() } catch {
            throw CLIError.usage(
                "Invalid --ssl-client-map. Use a version 1 JSON file within 64 KiB with 1–16 entries, each containing origin and either certificate/key or pkcs12 and a passphraseFile for encrypted PEM. No requests sent; input content omitted."
            )
        }
    }

    var referencedInputs: [URL] {
        mappedIdentities.flatMap(\.inputs).map { $0.resolvingSymlinksInPath() }
    }

    func planningTLS(_ args: Arguments) throws -> (identityDeclared: Bool, overridesTrust: Bool) {
        let ca = args.value("ca-cert") != nil
        let insecure = args.flags.contains("insecure")
        let certificate = args.value("ssl-client-cert") != nil
        let key = args.value("ssl-client-key") != nil
        let pkcs12 = args.value("ssl-client-p12") != nil
        let origin = args.value("ssl-client-origin")
        guard !(ca && insecure), ca || !args.flags.contains("include-system-roots"),
            certificate == key, !(pkcs12 && key), (pkcs12 || key) == (origin != nil),
            args.value("ssl-passphrase-file") == nil || pkcs12 || key
        else {
            throw CLIError.usage("Invalid TLS option combination. No requests sent.")
        }
        let origins = mappedIdentities.compactMap(\.origin) + [origin].compactMap { $0 }
        do {
            try FileTLSConfiguration.validateClientOrigins(origins)
        } catch {
            throw CLIError.usage(
                "TLS identity origins must be unique exact HTTPS origins. No requests sent.")
        }
        return (!origins.isEmpty, ca || insecure)
    }

    func load(_ args: Arguments) throws -> FileTLSConfiguration? {
        guard
            !Self.values.isDisjoint(with: args.values.keys)
                || !Self.flags.isDisjoint(with: args.flags)
        else { return nil }
        func file(_ name: String) -> URL? {
            args.value(name).map { URL(fileURLWithPath: $0) }
        }
        do {
            let ca = try file("ca-cert").map { try BoundedFileInput.read($0, limit: 1024 * 1024) }
            let insecure = args.flags.contains("insecure")
            let includeSystemRoots = args.flags.contains("include-system-roots")
            if !mappedIdentities.isEmpty {
                let trust = try FileTLSConfiguration(
                    caCertificates: ca, insecure: insecure, includeSystemRoots: includeSystemRoots)
                return try FileTLSConfiguration(
                    trust: trust, clientIdentities: mappedIdentities.map { try $0.configuration() })
            }
            return try IdentityFiles(
                origin: args.value("ssl-client-origin"), certificate: file("ssl-client-cert"),
                key: file("ssl-client-key"), pkcs12: file("ssl-client-p12"),
                passphraseFile: file("ssl-passphrase-file")
            ).configuration(ca: ca, insecure: insecure, includeSystemRoots: includeSystemRoots)
        } catch is CancellationError { throw CancellationError() } catch let error as CLIError {
            throw error
        } catch let error as FileTLSError {
            let reason: String
            switch error {
            case .invalidOptions:
                reason =
                    "Choose CA trust or --insecure, and one paired PEM or PKCS#12 identity with --ssl-client-origin. --include-system-roots requires --ca-cert."
            case .invalidOrigin:
                reason =
                    "Each client identity requires an exact HTTPS origin with an optional port and no credentials, path, query or fragment."
            case .duplicateOrigin:
                reason =
                    "Each origin in --ssl-client-map must be unique after normalizing host and port."
            case .missingKeyPassphrase:
                reason =
                    "Encrypted PEM keys require --ssl-passphrase-file or passphraseFile in the identity map."
            case .unexpectedKeyPassphrase:
                reason = "Omit the passphrase file when using an unencrypted PEM key."
            case .unsupportedKeyEncryption:
                reason =
                    "Encrypted PEM keys require PKCS#8 with PBKDF2, AES-CBC, an 8–64 byte salt and at most 1,000,000 iterations."
            case .invalidPassphrase:
                reason =
                    "Passphrase input must be bounded UTF-8 single-line text; one trailing line ending is allowed."
            case .invalidCertificate:
                reason =
                    "Certificate input must be bounded DER or a PEM bundle of at most 16 certificates."
            case .invalidIdentity:
                reason =
                    "Client identity is invalid, mismatched, expired or not yet valid. Check the key format and any passphrase file."
            }
            throw CLIError.usage(reason + " No requests sent; input content omitted.")
        } catch {
            throw CLIError.usage(
                "Could not read bounded TLS input files; no requests sent; paths and contents omitted."
            )
        }
    }

    private static func readPassphrase(_ file: URL) throws -> String {
        var bytes = try BoundedFileInput.read(file, limit: 4096)
        if bytes.suffix(2).elementsEqual([13, 10]) {
            bytes.removeLast(2)
        } else if bytes.last == 10 {
            bytes.removeLast()
        }
        guard let text = String(data: bytes, encoding: .utf8),
            !text.contains("\r"), !text.contains("\n"), !text.contains("\0")
        else { throw FileTLSError.invalidPassphrase }
        return text
    }
}

extension Arguments {
    var fileRunInputs: [URL] {
        let paths =
            ["config", "environment-file", "iteration-data", "globals", "attachments"]
            + FileTLSOptions.inputNames
        return (operands + paths.compactMap { value($0) })
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } + referencedRunInputs
    }

    func protectsFileRunInput(_ destination: URL) -> Bool {
        let target = destination.resolvingSymlinksInPath()
        let inputs = fileRunInputs
        if inputs.contains(target) { return true }
        // Different spellings can name the same file on a case-insensitive volume.
        let identity =
            try? target.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? NSObject
        guard let identity else { return false }
        return inputs.contains { input in
            let candidate = try? input.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier
            return candidate.map { identity.isEqual($0) } ?? false
        }
    }
}
