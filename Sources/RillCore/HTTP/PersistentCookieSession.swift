import CryptoKit
import Darwin
import Foundation
import Synchronization

public enum CookieSessionError: Error {
    case invalid, busy, originMismatch, insecureTransport, explicitCookieHeader, writeFailed
}

struct CookieSessionOrigin: Codable, Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host?.lowercased(), !host.isEmpty, host.utf8.count <= 255,
            url.user == nil, url.password == nil
        else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    var isValid: Bool {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") ? "[(host)]" : host
        components.port = port
        return components.url.flatMap(Self.init) == self
    }

    func permits(_ domain: String) -> Bool {
        let domain = domain.lowercased()
        if !domain.hasPrefix(".") { return domain == host }
        return host == domain.dropFirst() || host.hasSuffix(domain)
    }
}

final class CookieSessionScope: Sendable {
    private let bound: Mutex<CookieSessionOrigin?>

    init(_ origin: CookieSessionOrigin?) { bound = Mutex(origin) }

    var origin: CookieSessionOrigin? { bound.withLock { $0 } }

    func validate(_ request: URLRequest, insecure: Bool) throws {
        guard !insecure else { throw CookieSessionError.insecureTransport }
        guard request.value(forHTTPHeaderField: "Cookie") == nil else {
            throw CookieSessionError.explicitCookieHeader
        }
        guard let url = request.url, let origin = CookieSessionOrigin(url) else {
            throw CookieSessionError.invalid
        }
        try bound.withLock { current in
            guard current == nil || current == origin else {
                throw CookieSessionError.originMismatch
            }
            current = origin
        }
    }
}

private struct StoredCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    let secure: Bool
    let httpOnly: Bool
    let sameSite: String?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate
        secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly
        sameSite = cookie.sameSitePolicy?.rawValue
    }

    func restore(for origin: CookieSessionOrigin, now: Date) throws -> HTTPCookie? {
        guard HTTPEncoding.isHeaderName(name), path.hasPrefix("/"), origin.permits(domain),
            name.utf8.count + value.utf8.count + domain.utf8.count + path.utf8.count <= 8192,
            ![value, domain, path].contains(where: { text in
                text.utf8.contains { $0 < 32 || $0 == 127 }
            })
        else { throw CookieSessionError.invalid }
        if let expires, expires <= now { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path,
        ]
        if let expires { properties[.expires] = expires }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { properties[.sameSitePolicy] = sameSite }
        guard let cookie = HTTPCookie(properties: properties) else {
            throw CookieSessionError.invalid
        }
        return cookie
    }
}

public final class PersistentCookieSession {
    private struct Snapshot: Codable {
        let origin: CookieSessionOrigin
        let cookies: [StoredCookie]
    }

    private static let magic = Data("RillCookieSession/1\n".utf8)
    private static let maximumBytes = 256 * 1024
    private static let maximumCookies = 128

    public let jar: CookieJar
    private let url: URL
    private let key: SymmetricKey
    private var original: Data?
    private let scope: CookieSessionScope
    private let descriptor: Int32

    public init(file url: URL, keyFile: URL) throws {
        try Task.checkCancellation()
        let key = try Self.readKey(keyFile)
        let descriptor = Darwin.open(
            url.appendingPathExtension("lock").path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CookieSessionError.invalid }
        var initialized = false
        defer { if !initialized { Darwin.close(descriptor) } }
        guard BoundedFileInput.isPrivateRegularFile(descriptor) else {
            throw CookieSessionError.invalid
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw errno == EWOULDBLOCK ? CookieSessionError.busy : CookieSessionError.invalid
        }

        let original = try BoundedFileInput.readPrivate(url, limit: Self.maximumBytes)
        let snapshot: Snapshot?
        if let original {
            do {
                guard original.starts(with: Self.magic) else { throw CookieSessionError.invalid }
                let box = try AES.GCM.SealedBox(combined: original.dropFirst(Self.magic.count))
                let clear = try AES.GCM.open(box, using: key, authenticating: Self.magic)
                try WorkspaceFile.checkJSONBounds(clear)
                let decoded = try JSONDecoder().decode(Snapshot.self, from: clear)
                guard decoded.origin.isValid, decoded.cookies.count <= Self.maximumCookies else {
                    throw CookieSessionError.invalid
                }
                snapshot = decoded
            } catch is CancellationError { throw CancellationError() } catch {
                throw CookieSessionError.invalid
            }
        } else {
            snapshot = nil
        }
        let scope = CookieSessionScope(snapshot?.origin)
        let jar = CookieJar(scope: scope)
        if let snapshot {
            let now = Date()
            for record in snapshot.cookies {
                try Task.checkCancellation()
                if let cookie = try record.restore(for: snapshot.origin, now: now) {
                    jar.store(cookie)
                }
            }
        }
        self.jar = jar
        self.url = url
        self.key = key
        self.original = original
        self.scope = scope
        self.descriptor = descriptor
        initialized = true
    }

    deinit { Darwin.close(descriptor) }

    public func save() throws {
        try Task.checkCancellation()
        guard let origin = scope.origin else { throw CookieSessionError.invalid }
        let cookies = jar.cookies.filter {
            origin.permits($0.domain) && $0.version == 0 && $0.portList?.isEmpty != false
        }
        guard cookies.count <= Self.maximumCookies else { throw CookieSessionError.writeFailed }
        do {
            let snapshot = Snapshot(origin: origin, cookies: cookies.map(StoredCookie.init))
            // Verify that every record we write can be reopened with the same validation rules.
            let now = Date()
            for record in snapshot.cookies { _ = try record.restore(for: origin, now: now) }
            let data = try JSONEncoder().encode(snapshot)
            guard
                let sealed = try AES.GCM.seal(data, using: key, authenticating: Self.magic)
                    .combined,
                sealed.count <= Self.maximumBytes - Self.magic.count,
                try BoundedFileInput.readPrivate(url, limit: Self.maximumBytes) == original
            else { throw CookieSessionError.writeFailed }
            try Task.checkCancellation()
            let next = Self.magic + sealed
            try WorkspaceFile.atomicWrite(next, to: url, replaceExisting: original != nil)
            original = next
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CookieSessionError.writeFailed
        }
    }

    private static func readKey(_ url: URL) throws -> SymmetricKey {
        guard var bytes = try BoundedFileInput.readPrivate(url, limit: 66) else {
            throw CookieSessionError.invalid
        }
        if bytes.suffix(2).elementsEqual([13, 10]) {
            bytes.removeLast(2)
        } else if bytes.last == 10 {
            bytes.removeLast()
        }
        guard bytes.count == 64,
            bytes.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        else { throw CookieSessionError.invalid }
        let hex = Array(bytes)
        var key = Data()
        key.reserveCapacity(32)
        for offset in stride(from: 0, to: hex.count, by: 2) {
            guard
                let byte = UInt8(
                    String(decoding: hex[offset..<(offset + 2)], as: UTF8.self), radix: 16)
            else { throw CookieSessionError.invalid }
            key.append(byte)
        }
        return SymmetricKey(data: key)
    }
}
