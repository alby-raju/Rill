import Foundation

public enum StreamError: LocalizedError {
    case invalidEndpoint, invalidResponse, notConnected, busy, protocolMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Choose a ws:// or wss:// endpoint and a request timeout between 1 and 300 seconds."
        case .invalidResponse: "Expected a successful text/event-stream response. Redirects and automatic reconnect are disabled."
        case .notConnected: "The stream is not connected."
        case .busy: "The stream reached its bounded in-flight send limit."
        case .protocolMismatch: "The server did not negotiate the requested WebSocket subprotocol."
        }
    }
}
public enum StreamDirection: String, Codable, Sendable { case inbound, outbound, system }
public enum StreamKind: String, Codable, Sendable { case open, text, binary, close, error }
public struct StreamRecord: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let direction: StreamDirection
    public let kind: StreamKind
    public let data: Data
    public var text: String { String(data: data, encoding: .utf8) ?? data.base64EncodedString() }
    public init(direction: StreamDirection, kind: StreamKind, data: Data) { self.direction = direction; self.kind = kind; self.data = data }
}
public actor WebSocketClient {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var ready: CheckedContinuation<Void, Error>?
    private var receiver: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var callback: (@Sendable (StreamRecord) async -> Void)?
    private var generation = UUID()
    private var connected = false
    private var requestedProtocol: String?
    private var sentBytes = 0, inFlight = 0, retainedBytes = 0, records = 0
    private var timeout = 30.0
    public init() {}
    public func connect(_ input: RequestDraft, environment: Environment?, subprotocol: String? = nil,
                        profiles: [AuthenticationProfile] = [], secrets: NamedSecretResolver? = nil, tlsProfiles: [TLSProfile] = [],
                        onRecord: @escaping @Sendable (StreamRecord) async -> Void) async throws {
        guard socket == nil else { throw StreamError.busy }
        var draft = input
        guard var url = URLComponents(string: draft.url), ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { throw StreamError.invalidEndpoint }
        let scheme = url.scheme!.lowercased(); url.scheme = scheme == "wss" ? "https" : "http"
        draft.url = url.string!; draft.method = .GET; draft.bodyMode = RequestBodyMode.none; draft.graphql = nil
        let frozen = try RequestEngine.freeze(draft, environment: environment, profiles: profiles, secrets: secrets)
        var request = frozen.request
        guard var address = request.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { throw StreamError.invalidEndpoint }
        address.scheme = scheme; request.url = address.url
        guard request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == nil,
              subprotocol.map({ HTTPEncoding.isHeaderName($0) }) ?? true else { throw StreamError.protocolMismatch }
        if let subprotocol { request.setValue(subprotocol, forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        let profile = try TLSProfiles.selected(draft.tlsProfileID, from: tlsProfiles)
        let identity = try profile?.identityReference.map { try SystemTLSIdentities().identity(for: $0) }
        generation = UUID(); let id = generation
        self.callback = onRecord; requestedProtocol = subprotocol; timeout = request.timeoutInterval
        sentBytes = 0; inFlight = 0; retainedBytes = 0; records = 0
        let delegate = SocketDelegate(owner: self, generation: id, transport: HTTPTransportDelegate(prepared: frozen, profile: profile, identity: identity, followRedirects: false))
        let configuration = HTTPClientConfiguration.make()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 1024 * 1024; self.socket = socket
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)); await self?.expired(id) } catch { }
        }
        let timeout = timeout
        let handshake = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)); await self?.handshakeExpired(id) } catch { }
        }
        defer { handshake.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { ready = $0; socket.resume() }
        } onCancel: { Task { await self.stop() } }
    }
    fileprivate func opened(_ selected: String?, generation id: UUID) async {
        guard generation == id, let socket else { return }
        guard requestedProtocol == nil || requestedProtocol == selected else { ready?.resume(throwing: StreamError.protocolMismatch); ready = nil; stop(); return }
        connected = true; ready?.resume(); ready = nil
        await emit(StreamRecord(direction: .system, kind: .open, data: Data((selected ?? "Connected").utf8)), generation: id)
        guard generation == id else { return }
        receiver = Task { [weak self] in await self?.read(socket, generation: id) }
    }
    private func read(_ socket: URLSessionWebSocketTask, generation id: UUID) async {
        do {
            while !Task.isCancelled && generation == id {
                let message = try await socket.receive()
                try Task.checkCancellation()
                let record: StreamRecord
                switch message {
                case .string(let text): record = StreamRecord(direction: .inbound, kind: .text, data: Data(text.utf8))
                case .data(let data): record = StreamRecord(direction: .inbound, kind: .binary, data: data)
                @unknown default: throw GraphQLError.protocolFailure
                }
                guard record.data.count <= 1024 * 1024 else { throw WorkflowError.limit }
                guard records < 1000, retainedBytes <= 8 * 1024 * 1024 - record.data.count else { throw WorkflowError.limit }
                await emit(record, generation: id)
            }
        } catch { if generation == id { await ended(generation: id, code: "Receive ended", error: error is CancellationError ? nil : error) } }
    }
    public func send(text: String) async throws { try await send(.string(text), data: Data(text.utf8), kind: .text) }
    public func send(data: Data) async throws { try await send(.data(data), data: data, kind: .binary) }
    private func send(_ message: URLSessionWebSocketTask.Message, data: Data, kind: StreamKind) async throws {
        guard connected, let socket else { throw StreamError.notConnected }
        guard data.count <= 1024 * 1024 else { throw WorkflowError.limit }
        guard inFlight < 16, sentBytes <= 4 * 1024 * 1024 - data.count else { throw StreamError.busy }
        guard records < 1000, retainedBytes <= 8 * 1024 * 1024 - data.count else { throw WorkflowError.limit }
        inFlight += 1; sentBytes += data.count
        let id = generation, timeout = timeout
        defer { if generation == id { inFlight -= 1; sentBytes -= data.count } }
        let timer = Task { do { try await Task.sleep(for: .seconds(timeout)); socket.cancel(with: .goingAway, reason: nil) } catch { } }
        defer { timer.cancel() }
        try await withTaskCancellationHandler { try await socket.send(message) } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
        guard generation == id else { throw CancellationError() }
        await emit(StreamRecord(direction: .outbound, kind: kind, data: data), generation: id)
    }
    public func ping() async throws {
        try Task.checkCancellation()
        guard connected, let socket else { throw StreamError.notConnected }
        guard inFlight < 16 else { throw StreamError.busy }
        inFlight += 1; let id = generation, timeout = timeout
        defer { if generation == id { inFlight -= 1 } }
        let timer = Task { do { try await Task.sleep(for: .seconds(timeout)); socket.cancel(with: .goingAway, reason: nil) } catch { } }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in socket.sendPing { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } } }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
    private func emit(_ record: StreamRecord, generation id: UUID) async {
        guard generation == id else { return }
        let reserve = record.direction == .system ? 0 : 1024
        guard records < (record.direction == .system ? 1000 : 999), retainedBytes <= 8 * 1024 * 1024 - reserve - record.data.count else {
            if record.direction != .system { await ended(generation: id, code: "Timeline budget reached", error: WorkflowError.limit) }
            else { stop() }
            return
        }
        records += 1; retainedBytes += record.data.count
        if let callback { await callback(record) }
    }
    fileprivate func ended(generation id: UUID, code: String, error: Error?) async {
        guard generation == id else { return }
        ready?.resume(throwing: error ?? StreamError.notConnected); ready = nil
        await emit(StreamRecord(direction: .system, kind: error == nil ? .close : .error, data: Data(code.utf8)), generation: id)
        stop()
    }
    private func handshakeExpired(_ id: UUID) async { if generation == id && ready != nil { await ended(generation: id, code: "Handshake timed out", error: URLError(.timedOut)) } }
    private func expired(_ id: UUID) async { if generation == id { await ended(generation: id, code: "Session reached its five-minute lifetime", error: nil) } }
    public func stop() {
        generation = UUID(); connected = false
        ready?.resume(throwing: CancellationError()); ready = nil
        receiver?.cancel(); receiver = nil; deadline?.cancel(); deadline = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil; callback = nil
    }
    deinit { socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel(); receiver?.cancel(); deadline?.cancel() }
}
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: WebSocketClient?
    let generation: UUID
    let transport: HTTPTransportDelegate
    init(owner: WebSocketClient, generation: UUID, transport: HTTPTransportDelegate) { self.owner = owner; self.generation = generation; self.transport = transport }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) { Task { await owner?.opened(`protocol`, generation: generation) } }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) { Task { await owner?.ended(generation: generation, code: "Closed (\(closeCode.rawValue))", error: nil) } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { Task { await owner?.ended(generation: generation, code: "Transport closed", error: error) } } }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) { transport.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
