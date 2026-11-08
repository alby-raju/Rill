import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The PBES2/PBKDF2/AES-CBC subset of PKCS#8 encrypted private keys.
enum EncryptedPKCS8 {
    static let pemLabel = "ENCRYPTED PRIVATE KEY"
    private static let pbes2: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 5, 13]
    private static let pbkdf2: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 1, 5, 12]
    private static let hmacOID: [UInt8] = [0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 2]
    private static let aesOID: [UInt8] = [0x60, 0x86, 0x48, 1, 0x65, 3, 4, 1]
    private static let ecPublicKey: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 2, 1]

    static func decrypt(_ pemBody: Substring, passphrase: String) throws -> Data {
        guard let der = Data(base64Encoded: String(pemBody.filter { !$0.isWhitespace })) else {
            throw FileTLSError.invalidIdentity
        }
        var root = DER(der)
        var envelope = try DER(root.read(0x30))
        var algorithm = try DER(envelope.read(0x30))
        guard root.isEmpty, try algorithm.read(0x06).elementsEqual(pbes2) else {
            throw FileTLSError.unsupportedKeyEncryption
        }
        var parameters = try DER(algorithm.read(0x30))
        var derivation = try DER(parameters.read(0x30))
        var cipher = try DER(parameters.read(0x30))
        guard algorithm.isEmpty, parameters.isEmpty,
            try derivation.read(0x06).elementsEqual(pbkdf2)
        else { throw FileTLSError.unsupportedKeyEncryption }

        var kdf = try DER(derivation.read(0x30))
        let salt = try Array(kdf.read(0x04))
        let iterations = try kdf.positiveInteger()
        guard (8...64).contains(salt.count), (1...1_000_000).contains(iterations) else {
            throw FileTLSError.unsupportedKeyEncryption
        }
        let requestedKeySize = try kdf.tag == 0x02 ? kdf.positiveInteger() : nil
        let prf = try pseudorandomFunction(&kdf)

        let encryption = try cipher.read(0x06)
        let aesKeySizes = [UInt8(2): 16, 22: 24, 42: 32]
        guard encryption.count == aesOID.count + 1, encryption.starts(with: aesOID),
            let identifier = encryption.last, let keySize = aesKeySizes[identifier],
            requestedKeySize == nil || requestedKeySize == keySize
        else { throw FileTLSError.unsupportedKeyEncryption }
        let iv = try Array(cipher.read(0x04))
        let ciphertext = try Array(envelope.read(0x04))
        guard envelope.isEmpty, derivation.isEmpty, cipher.isEmpty,
            iv.count == kCCBlockSizeAES128, !ciphertext.isEmpty,
            ciphertext.count.isMultiple(of: kCCBlockSizeAES128)
        else { throw FileTLSError.invalidIdentity }

        try Task.checkCancellation()
        var key = Data(count: keySize)
        defer { key.resetBytes(in: 0..<keySize) }
        let derived = key.withUnsafeMutableBytes { output in
            passphrase.withCString { password in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, passphrase.utf8.count, salt, salt.count,
                    prf, UInt32(iterations), output.bindMemory(to: UInt8.self).baseAddress, keySize)
            }
        }
        guard derived == kCCSuccess else { throw FileTLSError.invalidIdentity }
        try Task.checkCancellation()
        var plaintext = Data(count: ciphertext.count)
        var written = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { bytes in
                CCCrypt(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding), bytes.baseAddress, keySize, iv,
                    ciphertext, ciphertext.count, output.baseAddress, output.count, &written)
            }
        }
        guard status == kCCSuccess, written > 0 else {
            plaintext.resetBytes(in: 0..<plaintext.count)
            throw FileTLSError.invalidIdentity
        }
        plaintext.removeSubrange(written..<plaintext.count)
        do {
            // Admit only clear PrivateKeyInfo here, never a nested encrypted container.
            var decrypted = DER(plaintext)
            var privateKey = try DER(decrypted.read(0x30))
            guard decrypted.isEmpty, try privateKey.read(0x02).elementsEqual([0]) else {
                throw FileTLSError.invalidIdentity
            }
            _ = try privateKey.read(0x30)
            guard try !privateKey.read(0x04).isEmpty else { throw FileTLSError.invalidIdentity }
            if !privateKey.isEmpty { _ = try privateKey.read(0xa0) }
            guard privateKey.isEmpty else { throw FileTLSError.invalidIdentity }
            return plaintext
        } catch {
            plaintext.resetBytes(in: 0..<plaintext.count)
            throw error
        }
    }

    static func ecPrivateKey(from plaintext: Data) throws -> SecKey? {
        var root = DER(plaintext)
        var privateKeyInfo = try DER(root.read(0x30))
        _ = try privateKeyInfo.read(0x02)
        var algorithm = try DER(privateKeyInfo.read(0x30))
        guard try algorithm.read(0x06).elementsEqual(ecPublicKey) else { return nil }
        let curve = try Array(algorithm.read(0x06))
        guard algorithm.isEmpty else { throw FileTLSError.invalidIdentity }
        var sec1 = DER(try privateKeyInfo.read(0x04))
        var key = try DER(sec1.read(0x30))
        guard sec1.isEmpty, try key.read(0x02).elementsEqual([1]) else {
            throw FileTLSError.invalidIdentity
        }
        let scalar = try key.read(0x04)
        if key.tag == 0xa0 {
            var parameters = try DER(key.read(0xa0))
            guard try parameters.read(0x06).elementsEqual(curve), parameters.isEmpty else {
                throw FileTLSError.invalidIdentity
            }
        }
        if key.tag == 0xa1 { _ = try key.read(0xa1) }
        guard key.isEmpty else { throw FileTLSError.invalidIdentity }

        // Derive the point from the scalar, so the certificate check cannot trust a
        // public point supplied inside a mismatched private key.
        var representation: Data
        do {
            switch curve {
            case [0x2a, 0x86, 0x48, 0xce, 0x3d, 3, 1, 7]:
                representation = try P256.Signing.PrivateKey(rawRepresentation: scalar)
                    .x963Representation
            case [0x2b, 0x81, 4, 0, 34]:
                representation = try P384.Signing.PrivateKey(rawRepresentation: scalar)
                    .x963Representation
            case [0x2b, 0x81, 4, 0, 35]:
                representation = try P521.Signing.PrivateKey(rawRepresentation: scalar)
                    .x963Representation
            default:
                throw FileTLSError.invalidIdentity
            }
        } catch {
            throw FileTLSError.invalidIdentity
        }
        defer { representation.resetBytes(in: 0..<representation.count) }
        let attributes =
            [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            ] as CFDictionary
        guard let result = SecKeyCreateWithData(representation as CFData, attributes, nil) else {
            throw FileTLSError.invalidIdentity
        }
        return result
    }

    private static func pseudorandomFunction(_ kdf: inout DER) throws -> CCPseudoRandomAlgorithm {
        guard !kdf.isEmpty else { return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1) }
        var prf = try DER(kdf.read(0x30))
        let oid = try prf.read(0x06)
        let algorithms = [
            UInt8(7): kCCPRFHmacAlgSHA1, 8: kCCPRFHmacAlgSHA224, 9: kCCPRFHmacAlgSHA256,
            10: kCCPRFHmacAlgSHA384, 11: kCCPRFHmacAlgSHA512,
        ]
        guard oid.count == hmacOID.count + 1, oid.starts(with: hmacOID),
            let identifier = oid.last, let algorithm = algorithms[identifier]
        else { throw FileTLSError.unsupportedKeyEncryption }
        if !prf.isEmpty {
            guard try prf.read(0x05).isEmpty else { throw FileTLSError.invalidIdentity }
        }
        guard prf.isEmpty, kdf.isEmpty else { throw FileTLSError.invalidIdentity }
        return CCPseudoRandomAlgorithm(algorithm)
    }

    // Fixed-depth parsing of definite, minimally encoded DER values. Never recurses or
    // trusts an advertised length before checking it against the bytes still available.
    private struct DER {
        private var bytes: Data
        init(_ bytes: Data) { self.bytes = bytes }
        var tag: UInt8? { bytes.first }
        var isEmpty: Bool { bytes.isEmpty }

        mutating func read(_ tag: UInt8) throws -> Data {
            guard bytes.popFirst() == tag, let first = bytes.popFirst() else {
                throw FileTLSError.invalidIdentity
            }
            var length = Int(first)
            if first >= 0x80 {
                let count = Int(first & 0x7f)
                guard (1...3).contains(count), count <= bytes.count, bytes.first != 0 else {
                    throw FileTLSError.invalidIdentity
                }
                length = bytes.prefix(count).reduce(0) { $0 * 256 + Int($1) }
                bytes = bytes.dropFirst(count)
                guard length >= 128 else { throw FileTLSError.invalidIdentity }
            }
            guard length <= bytes.count else { throw FileTLSError.invalidIdentity }
            let value = bytes.prefix(length)
            bytes = bytes.dropFirst(length)
            return value
        }

        mutating func positiveInteger() throws -> Int {
            let value = try read(0x02)
            guard (1...4).contains(value.count), let first = value.first, first < 0x80,
                first != 0 || (value.count > 1 && (value.dropFirst().first ?? 0) >= 0x80)
            else { throw FileTLSError.invalidIdentity }
            return value.reduce(0) { $0 * 256 + Int($1) }
        }
    }
}
