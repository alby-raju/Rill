import Foundation

public actor GraphQLSubscriptionClient {
    private enum Phase { case idle, awaitingAck, acknowledged, subscribed, finished }
    private let socket = WebSocketClient()
    private var phase: Phase = .idle
    private var ready: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?
    private var callback: (@Sendable (StreamRecord) async -> Void)?
    private var operationID = ""
    private var generation = UUID()
    private var stopping = false
    public init() {}
    public func start(_ input: RequestDraft, environment: Environment?, initPayload: String = "{}", profiles: [AuthenticationProfile] = [],
                      secrets: NamedSecretResolver? = nil, tlsProfiles: [TLSProfile] = [], onRecord: @escaping @Sendable (StreamRecord) async -> Void) async throws {
        guard !stopping, phase == .idle || phase == .finished, let configuration = input.graphql, initPayload.utf8.count <= 65536 else { throw GraphQLError.invalidInput }
        let prepared = try WorkflowEngine.prepare(input, variables: WorkflowEngine.variables(in: environment))
        func resolve(_ text: String) throws -> String {
            try VariableExpansion.resolve(text, values: prepared.variables, secretLookup: { name in guard let secrets else { throw AuthenticationError.missingSecret }; return try secrets.resolve(name) })
        }
        let initValue = try JSONValueParser(Data(resolve(initPayload).utf8)).parse()
        guard initValue.object != nil else { throw GraphQLError.invalidInput }
        let payload = try GraphQL.payload(configuration, resolve: resolve)
        generation = UUID(); let id = generation
        phase = .awaitingAck; callback = onRecord; operationID = UUID().uuidString
        do {
            try await socket.connect(prepared.request, environment: WorkflowEngine.environment(prepared.variables), subprotocol: "graphql-transport-ws", profiles: profiles, secrets: secrets, tlsProfiles: tlsProfiles, onRecord: { [weak self] record in await self?.received(record, generation: id) })
            try await send(.object([JSONKey("type"): .string(Data("connection_init".utf8)), JSONKey("payload"): initValue]))
            let timeout = min(30, input.timeout)
            timer = Task { [weak self] in do { try await Task.sleep(for: .seconds(timeout)); await self?.ackExpired(id) } catch { } }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if phase == .acknowledged { return }
                guard phase == .awaitingAck else { throw GraphQLError.protocolFailure }
                try await withCheckedThrowingContinuation { ready = $0 }
            } onCancel: { Task { await self.stopIfCurrent(id) } }
            timer?.cancel(); timer = nil
            guard generation == id else { throw CancellationError() }
            phase = .subscribed
            try await send(.object([JSONKey("id"): .string(Data(operationID.utf8)), JSONKey("type"): .string(Data("subscribe".utf8)), JSONKey("payload"): payload]))
        } catch { if generation == id { await stop() }; throw error }
    }
    private func send(_ value: JSONValue) async throws { try await socket.send(text: ResponseJSON.encoded(value)) }
    private func received(_ record: StreamRecord, generation id: UUID) async {
        guard generation == id else { return }
        if record.direction == .system {
            if let callback { await callback(record) }
            if record.kind == .close || record.kind == .error { ready?.resume(throwing: StreamError.notConnected); ready = nil; phase = .finished; timer?.cancel(); timer = nil }
            return
        }
        if record.direction == .outbound {
            if let callback {
                if let message = try? JSONValueParser(record.data).parse(), message["type"]?.string == "connection_init" {
                    await callback(StreamRecord(direction: .outbound, kind: .text, data: Data("connection_init (payload omitted)".utf8)))
                } else { await callback(record) }
            }
            return
        }
        do {
            guard record.kind == .text else { throw GraphQLError.protocolFailure }
            let message = try JSONValueParser(record.data).parse()
            guard let type = message["type"]?.string else { throw GraphQLError.protocolFailure }
            switch type {
            case "connection_ack":
                guard phase == .awaitingAck else { throw GraphQLError.protocolFailure }
                phase = .acknowledged; ready?.resume(); ready = nil; timer?.cancel(); timer = nil
            case "ping":
                var response: [JSONKey: JSONValue] = [JSONKey("type"): .string(Data("pong".utf8))]
                if let payload = message["payload"] { guard payload.object != nil else { throw GraphQLError.protocolFailure }; response[JSONKey("payload")] = payload }
                try await send(.object(response))
            case "pong": break
            case "next":
                guard phase == .subscribed, message["id"]?.string == operationID, let payload = message["payload"] else { throw GraphQLError.protocolFailure }
                guard try GraphQL.result(Data(ResponseJSON.encoded(payload).utf8)).valid else { throw GraphQLError.protocolFailure }
            case "error":
                guard phase == .subscribed, message["id"]?.string == operationID, message["payload"]?.array != nil else { throw GraphQLError.protocolFailure }
                if let callback { await callback(StreamRecord(direction: .inbound, kind: .error, data: record.data)) }; phase = .finished; await socket.stop(); return
            case "complete":
                guard phase == .subscribed, message["id"]?.string == operationID else { throw GraphQLError.protocolFailure }
                if let callback { await callback(record); await callback(StreamRecord(direction: .system, kind: .close, data: Data("Subscription complete".utf8))) }
                phase = .finished; await socket.stop(); return
            default: throw GraphQLError.protocolFailure
            }
            if let callback { await callback(record) }
        } catch {
            ready?.resume(throwing: error); ready = nil; phase = .finished; timer?.cancel(); timer = nil
            if let callback { await callback(StreamRecord(direction: .system, kind: .error, data: Data("Subscription protocol rejected".utf8))) }
            await socket.stop()
        }
    }
    private func ackExpired(_ id: UUID) async {
        guard generation == id, phase == .awaitingAck else { return }
        ready?.resume(throwing: URLError(.timedOut)); ready = nil
        if let callback { await callback(StreamRecord(direction: .system, kind: .error, data: Data("Subscription acknowledgement timed out".utf8))) }
        await stop()
    }
    private func stopIfCurrent(_ id: UUID) async { if generation == id { await stop() } }
    public func stop() async {
        guard !stopping else { return }; stopping = true
        defer { stopping = false }
        let sendComplete = phase == .subscribed, id = operationID
        generation = UUID(); ready?.resume(throwing: CancellationError()); ready = nil; timer?.cancel(); timer = nil
        phase = .finished; callback = nil
        if sendComplete {
            let closer = Task { [socket] in do { try await Task.sleep(for: .milliseconds(100)); await socket.stop() } catch { } }
            try? await socket.send(text: "{\"id\":\"" + id + "\",\"type\":\"complete\"}")
            closer.cancel()
        }
        await socket.stop()
    }
}
