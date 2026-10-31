import Foundation
import RillCore

enum FileTLSOptions {
    static let inputNames = [
        "ca-cert", "ssl-client-cert", "ssl-client-key", "ssl-client-p12", "ssl-passphrase-file",
    ]
    static let values = Set(inputNames + ["ssl-client-origin"])
    static let flags: Set<String> = ["insecure", "include-system-roots"]

    static func load(_ args: Arguments) throws -> FileTLSConfiguration? {
        guard !values.isDisjoint(with: args.values.keys) || !flags.isDisjoint(with: args.flags)
        else { return nil }
        guard args.value("ssl-passphrase-file") == nil || args.value("ssl-client-p12") != nil else {
            throw CLIError.usage(
                "--ssl-passphrase-file requires --ssl-client-p12; PEM keys must be unencrypted. No requests sent."
            )
        }
        func read(_ name: String, limit: Int) throws -> Data? {
            try args.value(name).map {
                try BoundedFileInput.read(URL(fileURLWithPath: $0), limit: limit)
            }
        }
        do {
            var passphrase = ""
            if let input = try read("ssl-passphrase-file", limit: 4096) {
                var bytes = input
                if bytes.suffix(2).elementsEqual([13, 10]) {
                    bytes.removeLast(2)
                } else if bytes.last == 10 {
                    bytes.removeLast()
                }
                guard let text = String(data: bytes, encoding: .utf8) else {
                    throw FileTLSError.invalidPassphrase
                }
                guard !text.contains("\r"), !text.contains("\n"), !text.contains("\0") else {
                    throw FileTLSError.invalidPassphrase
                }
                passphrase = text
            }
            return try FileTLSConfiguration(
                caCertificates: read("ca-cert", limit: 1024 * 1024),
                clientCertificate: read("ssl-client-cert", limit: 1024 * 1024),
                clientKey: read("ssl-client-key", limit: 1024 * 1024),
                pkcs12: read("ssl-client-p12", limit: 4 * 1024 * 1024),
                passphrase: passphrase, clientOrigin: args.value("ssl-client-origin"),
                insecure: args.flags.contains("insecure"),
                includeSystemRoots: args.flags.contains("include-system-roots"))
        } catch is CancellationError { throw CancellationError() } catch let error as FileTLSError {
            let reason: String
            switch error {
            case .invalidOptions:
                reason =
                    "Choose CA trust or --insecure, and one paired PEM or PKCS#12 identity with --ssl-client-origin. --include-system-roots requires --ca-cert."
            case .invalidOrigin:
                reason =
                    "--ssl-client-origin requires an exact HTTPS origin with an optional port and no credentials, path, query or fragment."
            case .invalidPassphrase:
                reason =
                    "Passphrase input must be bounded UTF-8 single-line text; one trailing line ending is allowed."
            case .invalidCertificate:
                reason =
                    "Certificate input must be bounded DER or a PEM bundle of at most 16 certificates."
            case .invalidIdentity:
                reason =
                    "Client identity is invalid, mismatched, expired or not yet valid. Use an unencrypted PEM key pair or one PKCS#12 identity with its correct passphrase."
            }
            throw CLIError.usage(reason + " No requests sent; input content omitted.")
        } catch {
            throw CLIError.usage(
                "Could not read bounded TLS input files; no requests sent; paths and contents omitted."
            )
        }
    }
}

extension Arguments {
    var fileRunInputs: [URL] {
        (operands
            + (["environment-file", "iteration-data"] + FileTLSOptions.inputNames).compactMap {
                value($0)
            })
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
    }
}
