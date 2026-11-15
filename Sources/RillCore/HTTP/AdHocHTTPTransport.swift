import Foundation
import Network
import Security

public struct HTTPRedirectHop: Sendable {
    public enum Decision: String, Sendable {
        case followed, disabled, crossOrigin = "cross-origin", limit
    }

    public let status: Int
    public let number: Int
    public let decision: Decision
}

public struct AdHocHTTPTransport: Sendable {
    public var proxy: ProxyConfiguration?
    public var maximumRedirects: Int?
    public var traceRedirect: (@Sendable (HTTPRedirectHop) -> Void)?
    public typealias StreamWriter = @Sendable (Data, @Sendable () -> Bool) throws -> Void
    public var stream: StreamWriter?

    public init() {}

    public static func proxyTLS(host: String, anchors: Data?) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        if let anchors {
            var profile = TLSProfile()
            profile.mode = .custom
            profile.includeSystemRoots = false
            profile.anchors = try FileTLSConfiguration.certificates(anchors).map {
                SecCertificateCopyData($0) as Data
            }
            sec_protocol_options_set_verify_block(
                options.securityProtocolOptions,
                { [profile] _, trust, finish in
                    let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                    finish(TLSProfiles.evaluate(reference, host: host, profile: profile))
                }, DispatchQueue(label: "org.rill.proxy-trust"))
        }
        return options
    }
}

final class HTTPResponseStream: @unchecked Sendable {
    private let lock = NSLock()
    private let write: AdHocHTTPTransport.StreamWriter
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(HTTPURLResponse, Int), Error>?
    private var cancelled = false
    // Response, count and write errors are owned by the serial URL session delegate queue.
    private var response: HTTPURLResponse?
    private var count = 0
    private var writeError: Error?

    init(write: @escaping AdHocHTTPTransport.StreamWriter) { self.write = write }

    func receive(in session: URLSession, request: URLRequest) async throws -> (HTTPURLResponse, Int)
    {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.withLock {
                    self.task = task
                    self.continuation = continuation
                    if cancelled { task.cancel() } else { task.resume() }
                }
            }
        } onCancel: {
            self.lock.withLock {
                self.cancelled = true
                self.task?.cancel()
            }
        }
    }

    func received(_ response: URLResponse) -> Bool {
        self.response = response as? HTTPURLResponse
        return self.response != nil
    }

    func received(_ data: Data, task: URLSessionTask) {
        guard writeError == nil else { return }
        do {
            try write(data) { self.lock.withLock { self.cancelled } }
            count += data.count
        } catch {
            writeError = error
            task.cancel()
        }
    }

    func complete(_ error: Error?) {
        let continuation = lock.withLock {
            let waiting = self.continuation
            self.continuation = nil
            task = nil
            return waiting
        }
        if let error = writeError ?? error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (response, count))
        } else {
            continuation?.resume(throwing: RillError.invalidURL)
        }
    }
}
