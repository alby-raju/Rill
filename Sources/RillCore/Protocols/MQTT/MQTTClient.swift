import Foundation

public struct MQTTConfiguration: Sendable {
    public var endpoint = "mqtt://localhost:1883"
    public var version: MQTTVersion = .v5
    public var clientID = "rill-" + UUID().uuidString
    public var username = "", password = ""
    public var timeout = 10.0
    public init() {}
}
public struct BrokerMessage: Sendable {
    public let destination: String
    public let payload: Data
    public let contentType: String?
    public let qos: MQTTQoS
    public let retained: Bool
}
public enum BrokerSessionEvent: Sendable {
    case connected, message(BrokerMessage), acknowledged(String), error(String), closed
}
public actor MQTTClient {
    private var stopping = false
    private struct Pending {
        let expected: UInt8
        let continuation: CheckedContinuation<Data, Error>
        let timer: Task<Void, Never>
    }
    private let wire = BrokerByteChannel()
    private var reader: Task<Void, Never>?, keepalive: Task<Void, Never>?
    private var callback: (@Sendable (BrokerSessionEvent) async -> Void)?
    private var version: MQTTVersion = .v5
    private var pending: [UInt16: Pending] = [:]
    private var incoming: [UInt16: BrokerMessage] = [:]
    private var incomingBytes = 0
    private var completedIncoming: Set<UInt16> = []
    private var nextID: UInt16 = 0
    private var reserved: Set<UInt16> = []
    private var connected = false, starting = false, pingOutstanding = false
    private var generation = UUID()
    private var timeout = 10.0
    private var eventCount = 0, eventBytes = 0
    private var maximumQoS = 2, retainAvailable = true, wildcardAvailable = true
    private var serverReceiveMaximum = 16, serverPacketMaximum = 1024 * 1024 + 16389
    public init() {}
    public func connect(
        _ configuration: MQTTConfiguration,
        onEvent: @escaping @Sendable (BrokerSessionEvent) async -> Void
    ) async throws {
        guard !connected && !starting && !stopping, !configuration.clientID.isEmpty,
            configuration.clientID.utf8.count <= 128,
            configuration.username.utf8.count <= 4096, configuration.password.utf8.count <= 4096,
            configuration.timeout.isFinite, (1...300).contains(configuration.timeout)
        else { throw BrokerError.configuration }
        let secure =
            URLComponents(string: configuration.endpoint)?.scheme.map {
                ["ssl", "mqtts", "wss"].contains($0.lowercased())
            } ?? false
        // Plaintext is explicit in the endpoint; never upgrade or downgrade implicitly.
        let port: UInt16 = secure ? 8883 : 1883
        starting = true
        version = configuration.version
        timeout = configuration.timeout
        callback = onEvent
        generation = UUID()
        let id = generation
        eventCount = 0
        eventBytes = 0
        maximumQoS = 2
        retainAvailable = true
        wildcardAvailable = true
        serverReceiveMaximum = 16
        serverPacketMaximum = 1024 * 1024 + 16389
        do {
            var body = try MQTTEncoding.string("MQTT")
            body.append(version == .v5 ? 5 : 4)
            let flags: UInt8 =
                2 | (configuration.username.isEmpty && configuration.password.isEmpty ? 0 : 128)
                | (configuration.password.isEmpty ? 0 : 64)
            body.append(flags)
            body += MQTTEncoding.u16(30)
            if version == .v5 {
                // Receive Maximum=16, Maximum Packet Size=1 MiB+16 KiB+5. Topic Alias Maximum defaults to zero.
                let properties = Data([0x21, 0, 16, 0x27, 0, 0x10, 0x40, 5])
                body += MQTTEncoding.variable(properties.count) + properties
            }
            body += try MQTTEncoding.string(configuration.clientID)
            if flags & 128 != 0 { body += try MQTTEncoding.string(configuration.username) }
            if flags & 64 != 0 {
                let password = Data(configuration.password.utf8)
                body += MQTTEncoding.u16(UInt16(password.count)) + password
            }
            let packet = try MQTTEncoding.packet(0x10, body)
            try await wire.connect(
                configuration.endpoint, defaultPort: port, tlsSchemes: ["ssl", "mqtts"],
                plainSchemes: ["tcp", "mqtt"], websocketProtocol: "mqtt", timeout: timeout)
            guard generation == id else { throw CancellationError() }
            reader = Task { await self.read(id) }
            let response = try await exchange(packet, id: 0, expected: 2)
            var interval = 10.0
            var responseReader = MQTTReader(data: response)
            let responseFlags = try responseReader.byte()
            let reason = try responseReader.byte()
            guard responseFlags == 0 else { throw BrokerError.protocolFailure }
            guard reason == 0 else { throw BrokerError.rejected(Int(reason)) }
            if version == .v5 {
                let properties = try responseReader.properties()
                if let value = properties[0x13]?.first {
                    var cursor = MQTTReader(data: value)
                    let keepalive = try cursor.u16()
                    if keepalive > 0 { interval = min(10, Double(keepalive) / 2) }
                }
                guard
                    Set(properties.keys).isSubset(of: [
                        0x11, 0x12, 0x13, 0x15, 0x16, 0x1A, 0x1C, 0x1F, 0x21, 0x22, 0x24, 0x25,
                        0x26, 0x27, 0x28, 0x29, 0x2A,
                    ])
                else { throw BrokerError.protocolFailure }
                if let value = properties[0x24]?.first {
                    maximumQoS = Int(value.first!)
                    guard maximumQoS <= 1 else { throw BrokerError.protocolFailure }
                }
                if let value = properties[0x25]?.first {
                    guard value.first! <= 1 else { throw BrokerError.protocolFailure }
                    retainAvailable = value.first == 1
                }
                if let value = properties[0x28]?.first {
                    guard value.first! <= 1 else { throw BrokerError.protocolFailure }
                    wildcardAvailable = value.first == 1
                }
                if let value = properties[0x21]?.first {
                    var reader = MQTTReader(data: value)
                    let count = try reader.u16()
                    guard count > 0 else { throw BrokerError.protocolFailure }
                    serverReceiveMaximum = min(16, Int(count))
                }
                if let value = properties[0x27]?.first {
                    let count = value.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    guard count > 0 else { throw BrokerError.protocolFailure }
                    serverPacketMaximum = min(serverPacketMaximum, Int(count))
                }
                // Authentication challenge/server redirection/session takeover are deliberately unsupported.
                guard properties[0x15] == nil, properties[0x16] == nil, properties[0x1C] == nil
                else { throw BrokerError.protocolFailure }
            }
            guard responseReader.remaining == 0, generation == id else {
                throw BrokerError.protocolFailure
            }
            connected = true
            starting = false
            await emit(.connected, bytes: 0)
            guard generation == id else { throw CancellationError() }
            let keepaliveInterval = interval
            keepalive = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(keepaliveInterval))
                        try await self.ping(id)
                    }
                } catch { if !Task.isCancelled { await self.failed(id) } }
            }
        } catch {
            if generation == id { await stop() }
            throw error
        }
    }
    public func subscribe(_ filter: String, qos: MQTTQoS = .atMostOnce) async throws {
        guard connected, MQTTEncoding.topic(filter, subscription: true),
            !filter.hasPrefix("$share/"),
            wildcardAvailable || (!filter.contains("#") && !filter.contains("+"))
        else { throw BrokerError.configuration }
        let sessionID = generation
        let id = try allocate()
        defer { if generation == sessionID { reserved.remove(id) } }
        var body = MQTTEncoding.u16(id)
        if version == .v5 { body.append(0) }
        body += try MQTTEncoding.string(filter)
        body.append(UInt8(qos.rawValue))
        let response = try await exchange(MQTTEncoding.packet(0x82, body), id: id, expected: 9)
        var reader = MQTTReader(data: response)
        _ = try reader.u16()
        if version == .v5 { _ = try reader.properties() }
        guard reader.remaining == 1 else { throw BrokerError.protocolFailure }
        let result = try reader.byte()
        guard result < 128 else { throw BrokerError.rejected(Int(result)) }
        guard result <= UInt8(qos.rawValue), generation == sessionID else {
            throw BrokerError.protocolFailure
        }
        await emit(.acknowledged("Subscription accepted (QoS \(result))"), bytes: 0)
    }
    public func publish(
        topic: String, payload: Data, qos: MQTTQoS = .atMostOnce, retain: Bool = false,
        contentType: String? = nil, payloadIsUTF8: Bool = false
    ) async throws {
        guard connected, MQTTEncoding.topic(topic, subscription: false),
            payload.count <= 1024 * 1024,
            qos.rawValue <= maximumQoS, !retain || retainAvailable,
            contentType == nil || version == .v5,
            !payloadIsUTF8 || String(data: payload, encoding: .utf8) != nil
        else { throw BrokerError.configuration }
        let sessionID = generation
        let id: UInt16 = qos == .atMostOnce ? 0 : try allocate()
        defer { if id != 0 && generation == sessionID { reserved.remove(id) } }
        var body = try MQTTEncoding.string(topic)
        if id != 0 { body += MQTTEncoding.u16(id) }
        if version == .v5 {
            var properties = Data()
            if payloadIsUTF8 { properties += Data([1, 1]) }
            if let contentType {
                properties.append(3)
                properties += try MQTTEncoding.string(contentType)
            }
            guard properties.count <= 16384 else { throw BrokerError.limit }
            body += MQTTEncoding.variable(properties.count) + properties
        }
        body += payload
        let packet = try MQTTEncoding.packet(
            0x30 | UInt8(qos.rawValue << 1) | (retain ? 1 : 0), body)
        if qos == .atMostOnce {
            try await write(packet)
            await emit(.acknowledged("QoS 0 written (no broker acknowledgement)"), bytes: 0)
        } else {
            let first = try await exchange(packet, id: id, expected: qos == .atLeastOnce ? 4 : 5)
            try acknowledgement(first, id: id)
            if qos == .exactlyOnce {
                try acknowledgement(
                    await exchange(
                        MQTTEncoding.packet(0x62, MQTTEncoding.u16(id)), id: id, expected: 7),
                    id: id)
            }
            guard generation == sessionID else { throw CancellationError() }
            await emit(.acknowledged("Publish acknowledged (QoS \(qos.rawValue))"), bytes: 0)
        }
    }
    private func allocate() throws -> UInt16 {
        guard reserved.count < min(16, serverReceiveMaximum) else { throw BrokerError.limit }
        for _ in 0..<65535 {
            nextID = nextID == 65535 ? 1 : nextID + 1
            if !reserved.contains(nextID) {
                reserved.insert(nextID)
                return nextID
            }
        }
        throw BrokerError.limit
    }
    private func write(_ packet: Data) async throws {
        guard packet.count <= serverPacketMaximum else { throw BrokerError.limit }
        try await wire.write(packet)
    }
    private func exchange(_ packet: Data, id: UInt16, expected: UInt8) async throws -> Data {
        guard pending[id] == nil, pending.count < 16 else { throw BrokerError.limit }
        let generation = generation
        let timeout = timeout
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        await self.failed(generation)
                    } catch {}
                }
                pending[id] = Pending(expected: expected, continuation: continuation, timer: timer)
                Task { do { try await self.write(packet) } catch { await self.failed(generation) } }
            }
        } onCancel: {
            Task { await self.stopIfCurrent(generation) }
        }
    }
    private func acknowledgement(_ data: Data, id: UInt16) throws {
        var reader = MQTTReader(data: data)
        guard try reader.u16() == id else { throw BrokerError.protocolFailure }
        if version == .v5 && reader.remaining > 0 {
            let reason = try reader.byte()
            guard reason < 128 else { throw BrokerError.rejected(Int(reason)) }
            if reader.remaining > 0 { _ = try reader.properties() }
        }
        guard reader.remaining == 0 else { throw BrokerError.protocolFailure }
    }
    private func read(_ id: UUID) async {
        var decoder = MQTTDecoder()
        do {
            while generation == id && !Task.isCancelled {
                let packets = try decoder.append(await wire.read())
                for packet in packets {
                    guard generation == id else { return }
                    try await received(packet)
                }
            }
        } catch { if generation == id { await failed(id) } }
    }
    private func received(_ packet: MQTTPacket) async throws {
        let requiredFlags: UInt8 = packet.type == 6 ? 2 : 0
        guard packet.type == 3 || packet.header & 15 == requiredFlags else {
            throw BrokerError.protocolFailure
        }
        switch packet.type {
        case 2, 4, 5, 7, 9:
            var reader = MQTTReader(data: packet.body)
            let id: UInt16 = packet.type == 2 ? 0 : try reader.u16()
            guard let waiting = pending[id], waiting.expected == packet.type else {
                throw BrokerError.protocolFailure
            }
            pending[id] = nil
            waiting.timer.cancel()
            waiting.continuation.resume(returning: packet.body)
        case 3:
            guard connected else { throw BrokerError.protocolFailure }
            let qosBits = Int((packet.header >> 1) & 3)
            guard let qos = MQTTQoS(rawValue: qosBits), qos != .atMostOnce || packet.header & 8 == 0
            else { throw BrokerError.protocolFailure }
            var reader = MQTTReader(data: packet.body)
            let topic = try reader.string()
            guard MQTTEncoding.topic(topic, subscription: false) else {
                throw BrokerError.protocolFailure
            }
            let identifier = qos == .atMostOnce ? 0 : try reader.u16()
            guard qos == .atMostOnce || identifier != 0 else { throw BrokerError.protocolFailure }
            var contentType: String?
            var utf8 = false
            if version == .v5 {
                let properties = try reader.properties()
                guard Set(properties.keys).isSubset(of: [1, 2, 3, 8, 9, 0x0B, 0x26]),
                    properties[0x23] == nil
                else { throw BrokerError.protocolFailure }
                if let value = properties[1]?.first {
                    guard value.first! <= 1 else { throw BrokerError.protocolFailure }
                    utf8 = value.first == 1
                }
                if let value = properties[3]?.first {
                    var reader = MQTTReader(data: value)
                    contentType = try reader.string()
                }
            }
            let payload = try reader.take(reader.remaining)
            guard payload.count <= 1024 * 1024,
                !utf8 || String(data: payload, encoding: .utf8) != nil
            else { throw BrokerError.limit }
            let message = BrokerMessage(
                destination: topic, payload: payload, contentType: contentType, qos: qos,
                retained: packet.header & 1 != 0)
            if qos == .exactlyOnce {
                if let old = incoming[identifier] {
                    guard packet.header & 8 != 0, old.payload == payload, old.destination == topic
                    else { throw BrokerError.protocolFailure }
                } else {
                    guard incoming.count < 16, incomingBytes <= 2 * 1024 * 1024 - payload.count
                    else { throw BrokerError.limit }
                    completedIncoming.remove(identifier)
                    incoming[identifier] = message
                    incomingBytes += payload.count
                }
                try await write(MQTTEncoding.packet(0x50, MQTTEncoding.u16(identifier)))
            } else {
                if qos == .atLeastOnce {
                    try await write(MQTTEncoding.packet(0x40, MQTTEncoding.u16(identifier)))
                }
                await emit(.message(message), bytes: payload.count + topic.utf8.count)
            }
        case 6:
            var reader = MQTTReader(data: packet.body)
            let identifier = try reader.u16()
            guard identifier != 0 else { throw BrokerError.protocolFailure }
            try acknowledgement(packet.body, id: identifier)
            if let message = incoming.removeValue(forKey: identifier) {
                incomingBytes -= message.payload.count
                completedIncoming.insert(identifier)
                await emit(
                    .message(message), bytes: message.payload.count + message.destination.utf8.count
                )
            }
            // Repeated PUBREL must receive PUBCOMP without redelivery, including an unknown completed id.
            var acknowledgement = MQTTEncoding.u16(identifier)
            if version == .v5 && !completedIncoming.contains(identifier) {
                acknowledgement += Data([0x92, 0])
            }
            try await write(MQTTEncoding.packet(0x70, acknowledgement))
        case 13:
            guard packet.body.isEmpty, pingOutstanding else { throw BrokerError.protocolFailure }
            pingOutstanding = false
        case 14: throw BrokerError.closed
        default: throw BrokerError.protocolFailure
        }
    }
    private func ping(_ id: UUID) async throws {
        guard generation == id, connected, !pingOutstanding else { throw BrokerError.timeout }
        pingOutstanding = true
        try await write(MQTTEncoding.packet(0xC0))
    }
    private func emit(_ event: BrokerSessionEvent, bytes: Int) async {
        guard eventCount < 999, eventBytes <= 8 * 1024 * 1024 - bytes else {
            await failed(generation)
            return
        }
        eventCount += 1
        eventBytes += bytes
        if let callback { await callback(event) }
    }
    private func failed(_ id: UUID) async {
        guard generation == id else { return }
        if let callback {
            await callback(
                .error(
                    "MQTT session stopped: connection, acknowledgement, protocol or resource limit."
                ))
        }
        if generation == id { await stop() }
    }
    private func stopIfCurrent(_ id: UUID) async { if generation == id { await stop() } }
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        defer { stopping = false }
        generation = UUID()
        let callback = callback
        self.callback = nil
        connected = false
        starting = false
        reader?.cancel()
        reader = nil
        keepalive?.cancel()
        keepalive = nil
        for value in pending.values {
            value.timer.cancel()
            value.continuation.resume(throwing: BrokerError.closed)
        }
        pending = [:]
        incoming = [:]
        incomingBytes = 0
        completedIncoming = []
        pingOutstanding = false
        reserved = []
        await wire.close()
        if let callback { await callback(.closed) }
    }
}
