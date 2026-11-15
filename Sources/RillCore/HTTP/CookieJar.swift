import Foundation

/// A private, in-memory cookie store shared only by explicitly participating HTTP requests.
public final class CookieJar: Sendable {
    private let storage = URLSessionConfiguration.ephemeral.httpCookieStorage

    private let scope: CookieSessionScope?

    public init() { scope = nil }

    init(scope: CookieSessionScope) { self.scope = scope }

    var hasSessionScope: Bool { scope != nil }

    func prepare(_ request: inout URLRequest, insecure: Bool) throws {
        try scope?.prepare(&request, insecure: insecure)
    }

    func store(_ cookie: HTTPCookie) { storage?.setCookie(cookie) }

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
