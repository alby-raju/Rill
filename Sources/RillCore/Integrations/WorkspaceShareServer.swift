import CryptoKit
import Foundation
import Network

public actor WorkspaceShareServer {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var generation = UUID()
    private var digest = Data()
    private var response = Data(), head = Data()
    private let queue = DispatchQueue(label: "app.rill.share")
    public init() {}
    public func start(workspace: Workspace, token: String, port: UInt16 = 0, allowLAN: Bool = false)
        async throws -> URL
    {
        guard listener == nil, WorkspaceSharing.validToken(token) else { throw ShareError.invalid }
        let body = try WorkspaceSharing.encode(workspace)
        digest = Data(SHA256.hash(data: Data(token.utf8)))
        head = Data(
            "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Length: \(body.count)\r\n\r\n"
                .utf8)
        response = head + body
        generation = UUID()
        let id = generation
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: allowLAN ? "0.0.0.0" : "127.0.0.1",
            port: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.state(state, id: id) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection, id: id) }
        }
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in Task { await self?.expire(id) } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation {
                ready = $0
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { await self.stopIfCurrent(id) }
        }
    }
    private func state(_ state: NWListener.State, id: UUID) {
        guard generation == id else { return }
        switch state {
        case .ready:
            if let port = listener?.port {
                ready?.resume(
                    returning: URL(string: "http://127.0.0.1:\(port.rawValue)/workspace")!)
                ready = nil
            }
        case .failed: stop()
        default: break
        }
    }
    private func expire(_ id: UUID) { if generation == id && ready != nil { stop() } }
    private func stopIfCurrent(_ id: UUID) { if generation == id { stop() } }
    private func accept(_ connection: NWConnection, id: UUID) {
        guard generation == id, connections.count < 4 else {
            connection.cancel()
            return
        }
        let key = UUID()
        connections[key] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in Task { await self?.close(key) } }
        read(connection, key: key, data: Data())
    }
    private func close(_ key: UUID) { connections.removeValue(forKey: key)?.cancel() }
    private func read(_ connection: NWConnection, key: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - data.count) {
            [weak self] bytes, _, complete, error in
            Task {
                await self?.received(
                    connection, key: key, prior: data, next: bytes, complete: complete,
                    failed: error != nil)
            }
        }
    }
    private func received(
        _ connection: NWConnection, key: UUID, prior: Data, next: Data?, complete: Bool,
        failed: Bool
    ) {
        guard connections[key] != nil, !failed else {
            close(key)
            return
        }
        var data = prior
        data += next ?? Data()
        guard let delimiter = data.range(of: Data("\r\n\r\n".utf8)) else {
            if complete || data.count >= 8192 {
                close(key)
            } else {
                read(connection, key: key, data: data)
            }
            return
        }
        guard delimiter.upperBound == data.count,
            let text = String(data: data[..<delimiter.lowerBound], encoding: .ascii)
        else {
            close(key)
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(request[2])) else {
            close(key)
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                HTTPEncoding.isHeaderName(String(line[..<colon]))
            else {
                close(key)
                return
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil, value.utf8.allSatisfy({ (32...126).contains($0) }) else {
                close(key)
                return
            }
            headers[name] = value
        }
        let authorized =
            headers["authorization"].map {
                $0.hasPrefix("Bearer ")
                    && WorkspaceSharing.equalToken(String($0.dropFirst(7)), digest: digest)
            } ?? false
        let output: Data
        if !authorized {
            output = rejection(401)
        } else if headers["transfer-encoding"] != nil
            || ![nil, "0"].contains(headers["content-length"])
        {
            output = rejection(400)
        } else if request[1] != "/workspace" {
            output = rejection(404)
        } else if request[0] == "GET" {
            output = response
        } else if request[0] == "HEAD" {
            output = head
        } else {
            output = rejection(405)
        }
        connection.send(
            content: output,
            completion: .contentProcessed { [weak self] _ in Task { await self?.close(key) } })
    }
    private func rejection(_ status: Int) -> Data {
        Data(
            "HTTP/1.1 \(status) Rejected\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Length: 0\r\n\r\n"
                .utf8)
    }
    public func stop() {
        generation = UUID()
        ready?.resume(throwing: CancellationError())
        ready = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        response = Data()
        head = Data()
        digest = Data()
    }
    deinit {
        listener?.cancel()
        for connection in connections.values { connection.cancel() }
    }
}
