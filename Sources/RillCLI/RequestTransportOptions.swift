import Darwin
import Foundation
import Network
import RillCore

struct RequestTransportOptions {
    static let values: Set<String> = [
        "proxy", "proxy-user", "proxy-password-file", "proxy-bypass", "max-redirects",
        "resume-etag", "session-save-header",
    ]
    static let flags: Set<String> = ["stream", "show-redirects", "session-save-auth"]

    let transport: AdHocHTTPTransport
    let resumeETag: String?

    init(_ args: Arguments) throws {
        var transport = AdHocHTTPTransport()
        if let value = args.value("max-redirects") {
            guard let count = Int(value), (0...20).contains(count) else {
                throw CLIError.usage("--max-redirects expects a count from 0 to 20.")
            }
            transport.maximumRedirects = count
        }
        if args.flags.contains("show-redirects") {
            transport.traceRedirect = { status, followed in
                let line = "Redirect HTTP \(status) \(followed ? "followed" : "stopped")\n"
                try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
            }
        }
        if args.flags.contains("stream") {
            transport.stream = Self.writeStdout
        }
        transport.proxy = try Self.proxy(args)
        self.transport = transport
        resumeETag = args.value("resume-etag")
    }

    private static func writeStdout(_ data: Data, cancelled: @Sendable () -> Bool) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                if cancelled() { throw CancellationError() }
                let count = Darwin.write(
                    STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else if count < 0 && errno == EAGAIN {
                    var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, 100)
                } else {
                    throw CLIError.runtime
                }
            }
        }
    }

    private static func proxy(_ args: Arguments) throws -> ProxyConfiguration? {
        let user = args.value("proxy-user")
        let file = args.value("proxy-password-file")
        let bypass = args.values["proxy-bypass"] ?? []
        guard let value = args.value("proxy") else {
            guard user == nil, file == nil, bypass.isEmpty else {
                throw CLIError.usage("Proxy credentials and bypass domains require --proxy.")
            }
            return nil
        }
        guard let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
            ["http", "https", "socks5"].contains(scheme),
            let host = url.host, !host.isEmpty,
            let port = UInt16(
                exactly: url.port ?? (scheme == "socks5" ? 1080 : scheme == "https" ? 443 : 80)),
            port != 0, let endpointPort = NWEndpoint.Port(rawValue: port),
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.path.isEmpty || url.path == "/", (user == nil) == (file == nil),
            bypass.count <= 32,
            bypass.allSatisfy({ name in
                !name.isEmpty && name.utf8.count <= 253
                    && name.utf8.allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0)
                            || (97...122).contains($0) || $0 == 45 || $0 == 46
                    }
            })
        else {
            throw CLIError.usage(
                "Use --proxy with an HTTP, HTTPS or SOCKS5 proxy URL without userinfo.")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        var proxy =
            scheme == "socks5"
            ? ProxyConfiguration(socksv5Proxy: endpoint)
            : ProxyConfiguration(
                httpCONNECTProxy: endpoint, tlsOptions: scheme == "https" ? .init() : nil)
        proxy.allowFailover = false
        proxy.excludedDomains = bypass
        if let user, let file {
            guard !user.isEmpty, user.utf8.count <= 255,
                !user.utf8.contains(where: { $0 < 32 || $0 == 127 }),
                let bytes = try? BoundedFileInput.read(URL(fileURLWithPath: file), limit: 1024),
                let value = String(data: bytes, encoding: .utf8)
            else { throw CLIError.usage("Could not read bounded proxy credentials.") }
            let password = value.trimmingCharacters(in: .newlines)
            guard password.utf8.count <= 255,
                !password.utf8.contains(where: { $0 < 32 || $0 == 127 })
            else { throw CLIError.usage("Could not read bounded proxy credentials.") }
            proxy.applyCredential(username: user, password: password)
        }
        return proxy
    }
}
