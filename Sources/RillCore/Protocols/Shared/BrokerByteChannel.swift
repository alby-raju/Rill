import Foundation
import Network
import Security

public enum BrokerError: LocalizedError {
    case configuration, closed, timeout, protocolFailure, rejected(Int), limit
    public var errorDescription: String? {
        switch self {
        case .configuration: "Invalid broker endpoint or connection settings."
        case .closed: "The broker connection closed."
        case .timeout: "The broker operation timed out."
        case .protocolFailure: "The broker sent an unsupported or malformed protocol response."
        case .rejected(let code): "The broker rejected the operation (code \(code))."
        case .limit: "The broker session reached a configured resource limit."
        }
    }
}
/// One bounded binary channel; no reconnect, redirects, custom trust or credential discovery.
actor BrokerByteChannel {
    private var tcp: NWConnection?
    private var websocket: WebSocketClient?
    private var ready: CheckedContinuation<Void, Error>?
    private var reading: CheckedContinuation<Data, Error>?
    private var chunks: [Data] = []
    private var buffered = 0
    private var closed = true
    private var generation = UUID()
    private var pump: Task<Void, Never>?
    private var lifetime: Task<Void, Never>?
    private var writes = 0, writeBytes = 0
    private let queue = DispatchQueue(label: "app.rill.broker-wire")
    func connect(_ endpoint: String, defaultPort: UInt16, tlsSchemes: Set<String>, plainSchemes: Set<String>, websocketProtocol: String? = nil, timeout: Double = 10) async throws {
        guard closed, timeout.isFinite, (1...300).contains(timeout), let url = URLComponents(string: endpoint), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else { throw BrokerError.configuration }
        generation = UUID(); let id = generation; closed = false; chunks = []; buffered = 0; writes = 0; writeBytes = 0
        let timer = Task { do { try await Task.sleep(for: .seconds(timeout)); await self.expire(id) } catch { } }
        defer { timer.cancel() }
        do {
            if scheme == "ws" || scheme == "wss" {
                guard let websocketProtocol else { throw BrokerError.configuration }
                let socket = WebSocketClient(); websocket = socket
                var request = RequestDraft(); request.url = endpoint; request.timeout = timeout
                try await socket.connect(request, environment: nil, subprotocol: websocketProtocol, maximumMessageBytes: 1024 * 1024 + 65536, onRecord: { [weak self] record in await self?.websocketRecord(record, id: id) })
            } else {
                guard tlsSchemes.contains(scheme) || plainSchemes.contains(scheme), url.path.isEmpty || url.path == "/", url.query == nil,
                      let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? Int(defaultPort)) ?? 0), port.rawValue > 0 else { throw BrokerError.configuration }
                let parameters: NWParameters
                if tlsSchemes.contains(scheme) {
                    let options = NWProtocolTLS.Options()
                    sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
                    sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host)
                    parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options())
                } else { parameters = .tcp }
                let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters); tcp = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let owner = self else { return }
                    switch state {
                    case .ready: Task { await owner.connected(id) }
                    case .failed, .cancelled: Task { await owner.failed(id) }
                    default: break
                    }
                }
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation { ready = $0; connection.start(queue: queue) }
                } onCancel: { Task { await self.closeIfCurrent(id) } }
                pump = Task { [weak self] in await self?.receive(connection, id: id) }
            }
            guard generation == id, !closed else { throw BrokerError.closed }
            lifetime = Task { do { try await Task.sleep(for: .seconds(300)); await self.expire(id) } catch { } }
        } catch { if generation == id { await close() }; throw error }
    }
    private func connected(_ id: UUID) { guard generation == id else { return }; ready?.resume(); ready = nil }
    private func failed(_ id: UUID) async { if generation == id { await close() } }
    private func expire(_ id: UUID) async { if generation == id { ready?.resume(throwing: BrokerError.timeout); ready = nil; reading?.resume(throwing: BrokerError.timeout); reading = nil; await close() } }
    private func receive(_ connection: NWConnection, id: UUID) async {
        do {
            while generation == id && !Task.isCancelled {
                let packet: (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                        if error != nil { continuation.resume(throwing: BrokerError.closed) }
                        else { continuation.resume(returning: (data ?? Data(), complete)) }
                    }
                }
                guard generation == id else { return }
                if !packet.0.isEmpty { try enqueue(packet.0) }
                if packet.1 { await close(preserveBuffered: true); return }
            }
        } catch { if generation == id { await close() } }
    }
    private func websocketRecord(_ record: StreamRecord, id: UUID) async {
        guard generation == id else { return }
        if record.direction == .inbound {
            guard record.kind == .binary else { await close(); return }
            do { try enqueue(record.data) } catch { await close() }
        } else if record.kind == .close || record.kind == .error { await close() }
    }
    private func enqueue(_ data: Data) throws {
        guard buffered <= 4 * 1024 * 1024 - data.count else { throw BrokerError.limit }
        if let reading { self.reading = nil; reading.resume(returning: data) }
        else { guard chunks.count < 1024 else { throw BrokerError.limit }; chunks.append(data); buffered += data.count }
    }
    func read() async throws -> Data {
        try Task.checkCancellation()
        if !chunks.isEmpty { let next = chunks.removeFirst(); buffered -= next.count; return next }
        guard !closed, reading == nil else { throw BrokerError.closed }
        let id = generation
        return try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { reading = $0 } } onCancel: { Task { await self.closeIfCurrent(id) } }
    }
    func write(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !closed, data.count <= 1024 * 1024 + 65536, writes < 16, writeBytes <= 4 * 1024 * 1024 - data.count else { throw BrokerError.limit }
        let id = generation; writes += 1; writeBytes += data.count
        defer { if generation == id { writes -= 1; writeBytes -= data.count } }
        let timer = Task { do { try await Task.sleep(for: .seconds(30)); await self.expire(id) } catch { } }
        defer { timer.cancel() }
        if let websocket { try await websocket.send(data: data) }
        else if let tcp {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    tcp.send(content: data, completion: .contentProcessed { error in if error != nil { continuation.resume(throwing: BrokerError.closed) } else { continuation.resume() } })
                }
            } onCancel: { Task { await self.closeIfCurrent(id) } }
        } else { throw BrokerError.closed }
        guard generation == id else { throw BrokerError.closed }
    }
    private func closeIfCurrent(_ id: UUID) async { if generation == id { await close() } }
    func close(preserveBuffered: Bool = false) async {
        generation = UUID(); closed = true
        ready?.resume(throwing: BrokerError.closed); ready = nil; reading?.resume(throwing: BrokerError.closed); reading = nil
        pump?.cancel(); pump = nil; lifetime?.cancel(); lifetime = nil
        tcp?.cancel(); tcp = nil
        let socket = websocket; websocket = nil
        if !preserveBuffered { chunks = []; buffered = 0 }
        await socket?.stop()
    }
    deinit { tcp?.cancel(); pump?.cancel(); lifetime?.cancel() }
}
