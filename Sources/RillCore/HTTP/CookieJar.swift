import Foundation

/// A private, in-memory cookie store shared only by explicitly participating HTTP requests.
public final class CookieJar: Sendable {
    private let storage = URLSessionConfiguration.ephemeral.httpCookieStorage

    public init() {}

    public var cookies: [HTTPCookie] { storage?.cookies ?? [] }

    public func remove(_ cookie: HTTPCookie) {
        storage?.deleteCookie(cookie)
    }

    public func removeAll() {
        for cookie in cookies { remove(cookie) }
    }

    func configure(_ configuration: URLSessionConfiguration) {
        configuration.httpCookieStorage = storage
        configuration.httpShouldSetCookies = true
    }
}
