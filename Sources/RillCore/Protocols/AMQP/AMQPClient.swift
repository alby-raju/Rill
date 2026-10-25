import Foundation

public struct AMQPConfiguration: Sendable {
    public var endpoint = "amqp://localhost:5672"
    public var virtualHost = "/", username = "guest", password = ""
    public var timeout = 10.0
    public init() {}
}
public struct AMQPDelivery: Sendable {
    public let routingKey: String
    public let payload: Data
    public let contentType: String?
    public let redelivered: Bool
}
public enum AMQPEvent: Sendable {
    case connected, delivery(AMQPDelivery), acknowledged, error(String), closed
}
/// AMQP 0-9-1 existing-queue consumer and confirmed default-exchange publisher.
public actor AMQPClient {
    private var stopping = false
    private struct Waiting {
        let key: UInt64
        let continuation: CheckedContinuation<Data, Error>
        let timer: Task<Void, Never>
    }
    private struct Delivery {
        let tag: UInt64
        let routingKey: String
        let redelivered: Bool
        let returned: Bool
        var size: Int?
        var body = Data()
        var contentType: String?
    }
    private let wire = BrokerByteChannel()
    private var reader: Task<Void, Never>?, heartbeat: Task<Void, Never>?
    private var waiting: Waiting?
    private var publication: (UInt64, CheckedContinuation<Void, Error>, Task<Void, Never>)?
    private var incoming: Delivery?
    private var callback: (@Sendable (AMQPEvent) async -> Void)?
    private var generation = UUID()
    private var active = false, starting = false, blocked = false
    private var timeout = 10.0, heartbeatSeconds = 30.0
    private var lastRead = ContinuousClock.now
    private var maximumFrame = 65536
    private var nextPublication: UInt64 = 0
    private var consumerTag: String?
    private var events = 0, retainedBytes = 0
    public init() {}
    private func key(_ group: UInt16, _ method: UInt16, _ channel: UInt16) -> UInt64 {
        (UInt64(channel) << 32) | (UInt64(group) << 16) | UInt64(method)
    }
    public func connect(
        _ configuration: AMQPConfiguration, onEvent: @escaping @Sendable (AMQPEvent) async -> Void
    ) async throws {
        guard !active && !starting && !stopping, configuration.timeout.isFinite,
            (1...300).contains(configuration.timeout),
            configuration.username.utf8.count <= 4096, configuration.password.utf8.count <= 4096,
            !configuration.username.contains("\0"), !configuration.password.contains("\0")
        else { throw BrokerError.configuration }
        _ = try WireValue.shortString(configuration.virtualHost)
        starting = true
        generation = UUID()
        let id = generation
        callback = onEvent
        timeout = configuration.timeout
        events = 0
        retainedBytes = 0
        maximumFrame = 65536
        nextPublication = 0
        blocked = false
        consumerTag = nil
        lastRead = .now
        do {
            let secure =
                URLComponents(string: configuration.endpoint)?.scheme?.lowercased() == "amqps"
            try await wire.connect(
                configuration.endpoint, defaultPort: secure ? 5671 : 5672, tlsSchemes: ["amqps"],
                plainSchemes: ["amqp"], timeout: timeout)
            guard generation == id else { throw CancellationError() }
            reader = Task { await self.read(id) }
            let start = try await exchange(Data("AMQP\0\0\u{9}\u{1}".utf8), group: 10, method: 10)
            var startReader = WireCursor(data: start)
            guard try startReader.u8() == 0, try startReader.u8() == 9 else {
                throw BrokerError.protocolFailure
            }
            try startReader.table()
            let mechanisms = try startReader.text(Int(startReader.u32()))
            let locales = try startReader.text(Int(startReader.u32()))
            guard mechanisms.split(separator: " ").contains("PLAIN"),
                locales.split(separator: " ").contains("en_US"), startReader.remaining == 0
            else { throw BrokerError.protocolFailure }
            let credentials = Data(
                ("\0" + configuration.username + "\0" + configuration.password).utf8)
            var arguments = WireValue.u32(0)
            arguments += try WireValue.shortString("PLAIN")
            arguments += try WireValue.longBytes(credentials)
            arguments += try WireValue.shortString("en_US")
            let tune = try await exchange(
                AMQPEncoding.method(10, 11, arguments: arguments), group: 10, method: 30)
            var tuneReader = WireCursor(data: tune)
            _ = try tuneReader.u16()
            let frameMax = try tuneReader.u32()
            let heartbeat = try tuneReader.u16()
            guard tuneReader.remaining == 0, frameMax == 0 || frameMax >= 4096 else {
                throw BrokerError.protocolFailure
            }
            maximumFrame = frameMax == 0 ? 65536 : min(65536, Int(frameMax))
            heartbeatSeconds = heartbeat == 0 ? 30 : min(30, Double(heartbeat))
            let tuneOK =
                WireValue.u16(1) + WireValue.u32(UInt32(maximumFrame))
                + WireValue.u16(UInt16(heartbeatSeconds))
            try await wire.write(AMQPEncoding.method(10, 31, arguments: tuneOK))
            let open =
                try WireValue.shortString(configuration.virtualHost) + WireValue.shortString("")
                + Data([0])
            _ = try await exchange(
                AMQPEncoding.method(10, 40, arguments: open), group: 10, method: 41)
            _ = try await exchange(
                AMQPEncoding.method(20, 10, channel: 1, arguments: Data([0])), group: 20,
                method: 11, channel: 1)
            _ = try await exchange(
                AMQPEncoding.method(
                    60, 10, channel: 1, arguments: WireValue.u32(0) + WireValue.u16(16) + Data([0])),
                group: 60, method: 11, channel: 1)
            _ = try await exchange(
                AMQPEncoding.method(85, 10, channel: 1, arguments: Data([0])), group: 85,
                method: 11, channel: 1)
            guard generation == id else { throw CancellationError() }
            active = true
            starting = false
            await emit(.connected, bytes: 0)
            guard generation == id else { throw CancellationError() }
            self.heartbeat = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(max(0.5, self.heartbeatSeconds / 2)))
                        guard self.generation == id else { return }
                        guard self.lastRead.duration(to: .now) < .seconds(self.heartbeatSeconds * 2)
                        else { throw BrokerError.timeout }
                        try await self.wire.write(AMQPEncoding.frame(8))
                    }
                } catch { if self.generation == id { await self.failed(id) } }
            }
        } catch {
            if generation == id { await stop() }
            throw error
        }
    }
    public func consume(queue: String) async throws {
        guard active, consumerTag == nil, !queue.isEmpty, publication == nil else {
            throw BrokerError.configuration
        }
        let arguments =
            try WireValue.u16(0) + WireValue.shortString(queue) + Data([0, 0]) + WireValue.u32(0)
        let response = try await exchange(
            AMQPEncoding.method(60, 20, channel: 1, arguments: arguments), group: 60, method: 21,
            channel: 1)
        var reader = WireCursor(data: response)
        let tag = try reader.shortString()
        guard !tag.isEmpty, reader.remaining == 0 else { throw BrokerError.protocolFailure }
        consumerTag = tag
    }
    public func publish(queue: String, payload: Data, contentType: String? = nil) async throws {
        guard active, !blocked, publication == nil, waiting == nil, !queue.isEmpty,
            payload.count <= 1024 * 1024
        else { throw BrokerError.configuration }
        var frames = try AMQPEncoding.method(
            60, 40, channel: 1,
            arguments: WireValue.u16(0) + Data([0]) + WireValue.shortString(queue) + Data([1]))
        var header = WireValue.u16(60) + WireValue.u16(0) + WireValue.u64(UInt64(payload.count))
        if let contentType {
            header += WireValue.u16(0x8000)
            header += try WireValue.shortString(contentType)
        } else {
            header += WireValue.u16(0)
        }
        frames += try AMQPEncoding.frame(2, channel: 1, payload: header)
        let chunkSize = maximumFrame - 8
        for offset in stride(from: 0, to: payload.count, by: chunkSize) {
            frames += try AMQPEncoding.frame(
                3, channel: 1, payload: Data(payload.dropFirst(offset).prefix(chunkSize)))
        }
        guard frames.count <= 1024 * 1024 + 65536, nextPublication < UInt64.max else {
            throw BrokerError.limit
        }
        nextPublication += 1
        let sequence = nextPublication
        let id = generation
        let timeout = timeout
        let packet = frames
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        await self.failed(id)
                    } catch {}
                }
                publication = (sequence, continuation, timer)
                Task { do { try await self.wire.write(packet) } catch { await self.failed(id) } }
            }
        } onCancel: {
            Task { await self.stopIfCurrent(id) }
        }
        guard generation == id else { throw CancellationError() }
        await emit(.acknowledged, bytes: 0)
    }
    private func exchange(_ packet: Data, group: UInt16, method: UInt16, channel: UInt16 = 0)
        async throws -> Data
    {
        guard waiting == nil else { throw BrokerError.configuration }
        let id = generation
        let timeout = timeout
        let expected = key(group, method, channel)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        await self.failed(id)
                    } catch {}
                }
                waiting = Waiting(key: expected, continuation: continuation, timer: timer)
                Task { do { try await self.wire.write(packet) } catch { await self.failed(id) } }
            }
        } onCancel: {
            Task { await self.stopIfCurrent(id) }
        }
    }
    private func read(_ id: UUID) async {
        var decoder = AMQPDecoder()
        do {
            while generation == id && !Task.isCancelled {
                decoder.maximumFrame = maximumFrame
                let frames = try decoder.append(await wire.read())
                for frame in frames {
                    guard generation == id else { return }
                    lastRead = .now
                    try await received(frame, id: id)
                }
            }
        } catch { if generation == id { await failed(id) } }
    }
    private func received(_ frame: AMQPFrame, id: UUID) async throws {
        guard frame.channel <= 1 else { throw BrokerError.protocolFailure }
        if frame.kind == 8 { return }
        if frame.kind == 1 {
            var cursor = WireCursor(data: frame.payload)
            let group = try cursor.u16()
            let method = try cursor.u16()
            if (group == 10 && method == 50) || (group == 20 && method == 40) {
                let code = try cursor.u16()
                throw BrokerError.rejected(Int(code))
            }
            if group == 10 && method == 60 {
                blocked = true
                return
            }
            if group == 10 && method == 61 {
                blocked = false
                return
            }
            if group == 20 && method == 20 {
                let flow = try cursor.u8()
                guard flow <= 1, cursor.remaining == 0 else { throw BrokerError.protocolFailure }
                blocked = flow == 0
                try await wire.write(
                    AMQPEncoding.method(20, 21, channel: 1, arguments: Data([flow])))
                return
            }
            if group == 60 && (method == 60 || method == 50) {
                guard active, incoming == nil, frame.channel == 1 else {
                    throw BrokerError.protocolFailure
                }
                if method == 60 {
                    _ = try cursor.shortString()
                    let tag = try cursor.u64()
                    let redelivered = try cursor.u8()
                    _ = try cursor.shortString()
                    let routing = try cursor.shortString()
                    guard tag > 0, redelivered <= 1, cursor.remaining == 0 else {
                        throw BrokerError.protocolFailure
                    }
                    incoming = Delivery(
                        tag: tag, routingKey: routing, redelivered: redelivered == 1,
                        returned: false)
                } else {
                    _ = try cursor.u16()
                    _ = try cursor.shortString()
                    _ = try cursor.shortString()
                    let routing = try cursor.shortString()
                    guard cursor.remaining == 0 else { throw BrokerError.protocolFailure }
                    incoming = Delivery(
                        tag: 0, routingKey: routing, redelivered: false, returned: true)
                }
                return
            }
            if group == 60 && (method == 80 || method == 120) {
                let tag = try cursor.u64()
                let flags = try cursor.u8()
                guard frame.channel == 1, flags & ~UInt8(method == 120 ? 3 : 1) == 0,
                    cursor.remaining == 0, let publication,
                    tag == publication.0 || ((flags & 1 != 0) && (tag == 0 || tag >= publication.0))
                else { throw BrokerError.protocolFailure }
                self.publication = nil
                publication.2.cancel()
                if method == 120 {
                    publication.1.resume(throwing: BrokerError.rejected(0))
                } else {
                    publication.1.resume()
                }
                return
            }
            guard let waiting, waiting.key == key(group, method, frame.channel) else {
                throw BrokerError.protocolFailure
            }
            self.waiting = nil
            waiting.timer.cancel()
            waiting.continuation.resume(returning: try cursor.take(cursor.remaining))
            return
        }
        guard frame.channel == 1, var delivery = incoming else { throw BrokerError.protocolFailure }
        if frame.kind == 2 {
            guard delivery.size == nil else { throw BrokerError.protocolFailure }
            var cursor = WireCursor(data: frame.payload)
            guard try cursor.u16() == 60, try cursor.u16() == 0 else {
                throw BrokerError.protocolFailure
            }
            let size = try cursor.u64()
            guard size <= 1024 * 1024 else { throw BrokerError.limit }
            delivery.size = Int(size)
            let flags = try cursor.u16()
            guard flags & 3 == 0 else { throw BrokerError.protocolFailure }
            if flags & 0x8000 != 0 { delivery.contentType = try cursor.shortString() }
            if flags & 0x4000 != 0 { _ = try cursor.shortString() }
            if flags & 0x2000 != 0 { try cursor.table() }
            if flags & 0x1000 != 0 { _ = try cursor.u8() }
            if flags & 0x0800 != 0 { _ = try cursor.u8() }
            for flag: UInt16 in [0x0400, 0x0200, 0x0100, 0x0080] {
                if flags & flag != 0 { _ = try cursor.shortString() }
            }
            if flags & 0x0040 != 0 { _ = try cursor.u64() }
            for flag: UInt16 in [0x0020, 0x0010, 0x0008, 0x0004] {
                if flags & flag != 0 { _ = try cursor.shortString() }
            }
            guard cursor.remaining == 0 else { throw BrokerError.protocolFailure }
        } else if frame.kind == 3 {
            guard let size = delivery.size, delivery.body.count <= size - frame.payload.count else {
                throw BrokerError.protocolFailure
            }
            delivery.body += frame.payload
        } else {
            throw BrokerError.protocolFailure
        }
        incoming = delivery
        if let size = delivery.size, delivery.body.count == size {
            incoming = nil
            if delivery.returned {
                if let publication {
                    self.publication = nil
                    publication.2.cancel()
                    publication.1.resume(throwing: BrokerError.rejected(312))
                }
                // Close after a returned publish so a late confirm cannot be misattributed.
                throw BrokerError.rejected(312)
            }
            try await emitDelivery(delivery, id: id)
        }
    }
    private func emitDelivery(_ delivery: Delivery, id: UUID) async throws {
        guard events < 999,
            retainedBytes <= 8 * 1024 * 1024 - delivery.body.count - delivery.routingKey.utf8.count
        else { throw BrokerError.limit }
        await emit(
            .delivery(
                AMQPDelivery(
                    routingKey: delivery.routingKey, payload: delivery.body,
                    contentType: delivery.contentType, redelivered: delivery.redelivered)),
            bytes: delivery.body.count + delivery.routingKey.utf8.count)
        guard generation == id else { throw CancellationError() }
        try await wire.write(
            AMQPEncoding.method(
                60, 80, channel: 1, arguments: WireValue.u64(delivery.tag) + Data([0])))
    }
    private func emit(_ event: AMQPEvent, bytes: Int) async {
        guard events < 999, retainedBytes <= 8 * 1024 * 1024 - bytes else {
            await failed(generation)
            return
        }
        events += 1
        retainedBytes += bytes
        if let callback { await callback(event) }
    }
    private func failed(_ id: UUID) async {
        guard generation == id else { return }
        if let callback {
            await callback(
                .error(
                    "AMQP session stopped: connection, acknowledgement, protocol or resource limit."
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
        active = false
        starting = false
        let callback = callback
        self.callback = nil
        waiting?.timer.cancel()
        waiting?.continuation.resume(throwing: BrokerError.closed)
        waiting = nil
        if let publication {
            publication.2.cancel()
            publication.1.resume(throwing: BrokerError.closed)
        }
        publication = nil
        reader?.cancel()
        reader = nil
        heartbeat?.cancel()
        heartbeat = nil
        incoming = nil
        consumerTag = nil
        await wire.close()
        if let callback { await callback(.closed) }
    }
}
