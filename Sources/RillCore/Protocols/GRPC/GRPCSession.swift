import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices

public struct GRPCConfiguration: Sendable {
    public var endpoint = "grpcs://localhost:50051"
    public var timeout = 30.0
    /// String values; keys ending in -bin require base64. Never persisted by the session.
    public var metadata: [Field] = []
    public init() {}
}
struct GRPCDataSerializer: MessageSerializer, MessageDeserializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: Data) throws -> Bytes {
        guard message.count <= 1024 * 1024 else { throw BrokerError.limit }
        return Bytes(message)
    }
    func deserialize<Bytes: GRPCContiguousBytes>(_ bytes: Bytes) throws -> Data {
        guard bytes.count <= 1024 * 1024 else { throw BrokerError.limit }
        return bytes.withUnsafeBytes { Data($0) }
    }
}
public actor GRPCSession {
    private var task: Task<Void, Never>?
    private var input: AsyncThrowingStream<Data, Error>.Continuation?
    private var generation = UUID()
    private var callback: (@Sendable (StreamRecord) async -> Void)?
    private var inFlightBytes = 0, inFlightCount = 0, records = 0, recordBytes = 0
    private var mode: GRPCCallMode = .unary
    private var halfClosed = false
    public init() {}
    static func transport(_ configuration: GRPCConfiguration) throws
        -> HTTP2ClientTransport.TransportServices
    {
        guard configuration.timeout.isFinite, (1...300).contains(configuration.timeout),
            configuration.endpoint.utf8.count <= 16384,
            let url = URLComponents(string: configuration.endpoint),
            let scheme = url.scheme?.lowercased(),
            ["grpc", "grpcs", "http", "https"].contains(scheme),
            let rawHost = url.host, !rawHost.isEmpty, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
        else { throw BrokerError.configuration }
        let secure = scheme == "grpcs" || scheme == "https"
        let port = url.port ?? (secure ? 443 : 80)
        guard (1...65535).contains(port) else { throw BrokerError.configuration }
        let host =
            rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast()) : rawHost
        var config = HTTP2ClientTransport.TransportServices.Config.defaults
        config.http2.maxHeaderListSize = 16384
        return try HTTP2ClientTransport.TransportServices(
            target: .dns(host: host, port: port), transportSecurity: secure ? .tls : .plaintext,
            config: config)
    }
    static func metadata(_ rows: [Field]) throws -> Metadata {
        guard rows.count <= 64 else { throw BrokerError.limit }
        var result = Metadata()
        var bytes = 0
        for row in rows where row.enabled {
            let key = row.name
            guard !key.isEmpty, key.utf8.count <= 128,
                key.utf8.allSatisfy({
                    (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
                }),
                !key.hasPrefix("grpc-"),
                !["content-type", "te", "user-agent", "host"].contains(key),
                row.value.utf8.count <= 8192
            else { throw BrokerError.configuration }
            bytes += key.utf8.count + row.value.utf8.count
            guard bytes <= 16384 else { throw BrokerError.limit }
            if key.hasSuffix("-bin") {
                guard let value = Data(base64Encoded: row.value), value.count <= 4096 else {
                    throw BrokerError.configuration
                }
                result.addBinary(Array(value), forKey: key)
            } else {
                guard row.value.utf8.allSatisfy({ (32...126).contains($0) }) else {
                    throw BrokerError.configuration
                }
                result.addString(row.value, forKey: key)
            }
        }
        return result
    }
    public func start(
        _ configuration: GRPCConfiguration, method: ProtobufMethod, initialMessage: Data? = nil,
        onRecord: @escaping @Sendable (StreamRecord) async -> Void
    ) throws {
        guard task == nil else { throw BrokerError.configuration }
        let transport = try Self.transport(configuration)
        let metadata = try Self.metadata(configuration.metadata)
        guard
            method.mode == .clientStreaming || method.mode == .bidirectional
                || initialMessage != nil
        else { throw BrokerError.configuration }
        if let initialMessage {
            guard initialMessage.count <= 1024 * 1024 else { throw BrokerError.limit }
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(16))
        generation = UUID()
        let id = generation
        callback = onRecord
        mode = method.mode
        halfClosed = false
        input = pair.continuation
        inFlightBytes = 0
        inFlightCount = 0
        records = 0
        recordBytes = 0
        if let initialMessage { try enqueue(initialMessage) }
        if method.mode == .unary || method.mode == .serverStreaming {
            halfClosed = true
            pair.continuation.finish()
        }
        var options = CallOptions.defaults
        options.timeout = .seconds(configuration.timeout)
        options.waitForReady = false
        options.maxRequestMessageBytes = 1024 * 1024
        options.maxResponseMessageBytes = 1024 * 1024
        let callOptions = options
        task = Task {
            do {
                try await self.emit(
                    StreamRecord(
                        direction: .system, kind: .open, data: Data("Starting \(method.id)".utf8)),
                    id: id)
                try await withGRPCClient(transport: transport) { client in
                    let request = StreamingClientRequest(of: Data.self, metadata: metadata) {
                        writer in
                        for try await message in pair.stream {
                            try Task.checkCancellation()
                            try await writer.write(message)
                            try await self.written(message, id: id)
                        }
                    }
                    // Cardinality is enforced below and by the bounded producer; all gRPC modes use
                    // the same native HTTP/2 stream framing, without generated application stubs.
                    let descriptor = MethodDescriptor(
                        fullyQualifiedService: method.service, method: method.name)
                    try await client.bidirectionalStreaming(
                        request: request, descriptor: descriptor, serializer: GRPCDataSerializer(),
                        deserializer: GRPCDataSerializer(), options: callOptions
                    ) { response in
                        let contents = try response.accepted.get()
                        try await self.emitMetadata(
                            contents.metadata, label: "Initial metadata", id: id)
                        var received = 0
                        for try await part in contents.bodyParts {
                            switch part {
                            case .message(let data):
                                received += 1
                                guard
                                    method.mode == .serverStreaming || method.mode == .bidirectional
                                        || received == 1
                                else { throw BrokerError.protocolFailure }
                                try await self.emit(
                                    StreamRecord(direction: .inbound, kind: .binary, data: data),
                                    id: id)
                            case .trailingMetadata(let metadata):
                                try await self.emitMetadata(
                                    metadata, label: "Trailing metadata", id: id)
                            }
                        }
                        guard
                            method.mode == .serverStreaming || method.mode == .bidirectional
                                || received == 1
                        else { throw BrokerError.protocolFailure }
                    }
                }
                try await self.emit(
                    StreamRecord(
                        direction: .system, kind: .close, data: Data("gRPC status OK".utf8)), id: id
                )
            } catch {
                if self.generation == id {
                    let text: String
                    if let error = error as? RPCError {
                        text = "gRPC status: \(error.code) (server text omitted)"
                    } else {
                        text =
                            Task.isCancelled
                            ? "gRPC cancelled" : "gRPC transport/protocol/resource failure"
                    }
                    try? await self.emit(
                        StreamRecord(direction: .system, kind: .error, data: Data(text.utf8)),
                        id: id)
                }
            }
            if self.generation == id { self.finish() }
        }
    }
    private func enqueue(_ message: Data) throws {
        guard let input, !halfClosed, message.count <= 1024 * 1024, inFlightCount < 16,
            inFlightBytes <= 4 * 1024 * 1024 - message.count
        else { throw BrokerError.limit }
        switch input.yield(message) {
        case .enqueued:
            inFlightCount += 1
            inFlightBytes += message.count
        case .dropped: throw BrokerError.limit
        case .terminated: throw BrokerError.closed
        @unknown default: throw BrokerError.protocolFailure
        }
    }
    public func send(_ message: Data) throws {
        guard task != nil, mode == .clientStreaming || mode == .bidirectional else {
            throw BrokerError.configuration
        }
        try enqueue(message)
    }
    public func finishSending() throws {
        guard task != nil, !halfClosed else { throw BrokerError.closed }
        halfClosed = true
        input?.finish()
    }
    private func written(_ message: Data, id: UUID) async throws {
        guard generation == id else { throw CancellationError() }
        inFlightCount -= 1
        inFlightBytes -= message.count
        try await emit(StreamRecord(direction: .outbound, kind: .binary, data: message), id: id)
    }
    private func emitMetadata(_ metadata: Metadata, label: String, id: UUID) async throws {
        var lines = [label]
        var bytes = label.utf8.count
        var count = 0
        let sensitive: Set<String> = [
            "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key",
        ]
        for element in metadata {
            count += 1
            guard count <= 128 else { throw BrokerError.limit }
            let value = sensitive.contains(element.key) ? "[REDACTED]" : element.value.encoded()
            bytes += element.key.utf8.count + value.utf8.count + 2
            guard bytes <= 16384 else { throw BrokerError.limit }
            lines.append(element.key + ": " + value)
        }
        try await emit(
            StreamRecord(
                direction: .system, kind: .text, data: Data(lines.joined(separator: "\n").utf8)),
            id: id)
    }
    private func emit(_ record: StreamRecord, id: UUID) async throws {
        guard generation == id else { throw CancellationError() }
        let terminal = record.kind == .close || record.kind == .error
        guard records < (terminal ? 1000 : 999),
            recordBytes <= 8 * 1024 * 1024 - (terminal ? 0 : 1024) - record.data.count
        else { throw BrokerError.limit }
        records += 1
        recordBytes += record.data.count
        if let callback { await callback(record) }
    }
    private func finish() {
        input?.finish()
        input = nil
        callback = nil
        task = nil
        halfClosed = true
    }
    public func stop() {
        generation = UUID()
        input?.finish(throwing: CancellationError())
        task?.cancel()
        finish()
    }
}
