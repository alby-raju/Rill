import Foundation
import Network

/// A short-lived IPv4 loopback HTTP listener, never a general HTTP server.
public actor OAuthCallbackReceiver {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.rill.oauth.callback")
    private var ready: CheckedContinuation<URL, Error>?
    private var waiting: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var waitStarted = false
    private var connections: [UUID: NWConnection] = [:]
    private var redirect: URL?
    private let expectedState: String
    public init(expectedState: String) { self.expectedState = expectedState }
    public func start() async throws -> URL {
        guard listener == nil, result == nil else { throw OAuthError.invalidConfiguration }
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state) } }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: queue)
            }
        } onCancel: { Task { await self.stop() } }
    }
    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port, let continuation = ready else { return }
            let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")!
            redirect = url; ready = nil; continuation.resume(returning: url)
        case .failed(let error): finish(.failure(error))
        default: break
        }
    }
    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        receive(connection, id: id, buffer: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024 - buffer.count) { [weak self] data, _, complete, error in
            Task { await self?.received(data, complete: complete, failed: error != nil, connection: connection, id: id, buffer: buffer) }
        }
    }
    private func received(_ data: Data?, complete: Bool, failed: Bool, connection: NWConnection, id: UUID, buffer: Data) {
        guard connections[id] != nil else { connection.cancel(); return }
        var buffer = buffer; buffer.append(data ?? Data())
        guard !failed, !buffer.isEmpty else { connections.removeValue(forKey: id); connection.cancel(); return }
        guard buffer.count < 16 * 1024 else { respond(connection, id: id, status: 400, result: nil); return }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if complete { respond(connection, id: id, status: 400, result: nil) }
            else { receive(connection, id: id, buffer: buffer) }
            return
        }
        guard let header = String(data: buffer[..<end.lowerBound], encoding: .utf8), let redirect else { respond(connection, id: id, status: 400, result: nil); return }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { respond(connection, id: id, status: 400, result: nil); return }
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard hosts == ["127.0.0.1:\(redirect.port!)"] else { respond(connection, id: id, status: 400, result: nil); return }
        let target = String(first[1])
        guard URLComponents(string: target)?.path == redirect.path else { respond(connection, id: id, status: 404, result: nil); return }
        let outcome = Result { try OAuthClient.callbackCode(target: target, redirect: redirect, expectedState: expectedState) }
        let status: Int
        switch outcome { case .success: status = 200; case .failure: status = 400 }
        respond(connection, id: id, status: status, result: outcome)
    }
    private func respond(_ connection: NWConnection, id: UUID, status: Int, result: Result<String, Error>?) {
        let body = status == 200 ? "Authorization received. Return to Rill." : "Callback rejected. Return to Rill."
        let response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { await self?.responded(id: id, outcome: result) }
        })
    }
    private func responded(id: UUID, outcome: Result<String, Error>?) {
        connections.removeValue(forKey: id)
        if let outcome { finish(outcome) }
    }
    public func waitForCode(timeout: Duration = .seconds(180)) async throws -> String {
        guard !waitStarted, listener != nil || result != nil else { throw OAuthError.invalidConfiguration }
        waitStarted = true
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.readCode() }
            group.addTask { try await Task.sleep(for: timeout); throw OAuthError.timedOut }
            defer { group.cancelAll() }
            do { return try await group.next()! }
            catch { finish(.failure(error)); throw error }
        }
    }
    private func readCode() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            guard waiting == nil else { throw OAuthError.invalidConfiguration }
            return try await withCheckedThrowingContinuation { waiting = $0 }
        } onCancel: { Task { await self.stop() } }
    }
    public func stop() { finish(.failure(CancellationError())) }
    private func finish(_ outcome: Result<String, Error>) {
        guard result == nil else { return }
        result = outcome
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
        ready?.resume(throwing: outcome.failure ?? CancellationError()); ready = nil
        waiting?.resume(with: outcome); waiting = nil
    }
    deinit { listener?.cancel(); for connection in connections.values { connection.cancel() } }
}
private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}
