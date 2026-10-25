import Foundation
import Kafka
import Logging
import Security

public enum KafkaSecurity: String, CaseIterable, Sendable {
    case plaintext, tls, saslPlaintext, saslTLS
}
public struct KafkaConfiguration: Sendable {
    public var bootstrapServers = "localhost:9092", topic = "events",
        groupID = "rill-inspect-" + UUID().uuidString
    public var security: KafkaSecurity = .tls
    public var username = "", password = ""
    public var timeout = 10.0
    /// Nil inspects every existing partition (at most 16); a selection inspects only that partition.
    public var partition: Int?
    public init() {}
}
public actor KafkaSession {
    private var producer: KafkaProducer?
    private var task: Task<Void, Never>?
    private var starting = false, publishing = false
    private var callback: (@Sendable (StreamRecord) async -> Void)?
    private var generation = UUID()
    private var records = 0, bytes = 0
    private var topic = ""
    public init() {}
    static func validate(_ configuration: KafkaConfiguration) throws -> [String] {
        let servers = configuration.bootstrapServers.split(
            separator: ",", omittingEmptySubsequences: false
        ).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !servers.isEmpty, servers.count <= 16, configuration.timeout.isFinite,
            (1...60).contains(configuration.timeout),
            configuration.bootstrapServers.utf8.count <= 16384,
            !configuration.groupID.isEmpty, configuration.groupID.utf8.count <= 255,
            !configuration.groupID.contains("\0"),
            validTopic(configuration.topic), configuration.username.utf8.count <= 4096,
            configuration.password.utf8.count <= 4096,
            !configuration.username.contains("\0"), !configuration.password.contains("\0"),
            configuration.partition.map({ (0...Int(Int32.max)).contains($0) }) ?? true
        else { throw BrokerError.configuration }
        for server in servers {
            guard let address = URLComponents(string: "kafka://" + server),
                address.host?.isEmpty == false, let port = address.port, (1...65535).contains(port),
                address.path.isEmpty, address.user == nil, address.password == nil,
                address.query == nil, address.fragment == nil
            else { throw BrokerError.configuration }
        }
        if configuration.security == .saslPlaintext || configuration.security == .saslTLS {
            guard !configuration.username.isEmpty else { throw BrokerError.configuration }
        } else {
            guard configuration.username.isEmpty, configuration.password.isEmpty else {
                throw BrokerError.configuration
            }
        }
        return servers
    }
    static func validTopic(_ topic: String) -> Bool {
        !topic.isEmpty && topic.utf8.count <= 249 && topic != "." && topic != ".."
            && topic.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [45, 46, 95].contains($0)
            }
    }
    private static func trustPEM() throws -> String {
        var anchors: CFArray?
        guard SecTrustCopyAnchorCertificates(&anchors) == errSecSuccess,
            let certificates = anchors as? [SecCertificate], !certificates.isEmpty,
            certificates.count <= 1000
        else { throw BrokerError.configuration }
        var output = ""
        for certificate in certificates {
            let base64 = (SecCertificateCopyData(certificate) as Data).base64EncodedString(
                options: [.lineLength64Characters, .endLineWithLineFeed])
            output += "-----BEGIN CERTIFICATE-----\n" + base64 + "\n-----END CERTIFICATE-----\n"
            guard output.utf8.count <= 2 * 1024 * 1024 else { throw BrokerError.limit }
        }
        return output
    }
    static func configs(_ configuration: KafkaConfiguration) throws -> (
        KafkaProducerConfig, KafkaConsumerConfig
    ) {
        let servers = try validate(configuration)
        let milliseconds = Int(configuration.timeout * 1000)
        let security: KafkaConfig.SecurityProtocol
        switch configuration.security {
        case .plaintext: security = .plaintext
        case .tls: security = .ssl
        case .saslPlaintext: security = .sasl_plaintext
        case .saslTLS: security = .sasl_ssl
        }
        let pem =
            configuration.security == .tls || configuration.security == .saslTLS
            ? try trustPEM() : nil
        var producer = KafkaProducerConfig()
        var consumer = KafkaConsumerConfig()
        producer.bootstrapServers = servers
        consumer.bootstrapServers = servers
        producer.securityProtocol = security
        consumer.securityProtocol = security
        producer.metrics = .disabled
        consumer.metrics = .disabled
        producer.enableMetricsPush = false
        consumer.enableMetricsPush = false
        producer.statisticsIntervalMs = 0
        consumer.statisticsIntervalMs = 0
        producer.log_level = 0
        consumer.log_level = 0
        producer.allowAutoCreateTopics = false
        consumer.allowAutoCreateTopics = false
        producer.enableSslCertificateVerification = true
        consumer.enableSslCertificateVerification = true
        producer.sslEndpointIdentificationAlgorithm = .https
        consumer.sslEndpointIdentificationAlgorithm = .https
        producer.sslCaPem = pem
        consumer.sslCaPem = pem
        if configuration.security == .saslPlaintext || configuration.security == .saslTLS {
            producer.saslMechanism = "PLAIN"
            consumer.saslMechanism = "PLAIN"
            producer.saslUsername = configuration.username
            consumer.saslUsername = configuration.username
            producer.saslPassword = configuration.password
            consumer.saslPassword = configuration.password
        }
        producer.socketConnectionSetupTimeoutMs = milliseconds
        consumer.socketConnectionSetupTimeoutMs = milliseconds
        producer.socketTimeoutMs = milliseconds
        consumer.socketTimeoutMs = milliseconds
        producer.receiveMessageMaxBytes = 2 * 1024 * 1024
        consumer.receiveMessageMaxBytes = 2 * 1024 * 1024
        producer.messageMaxBytes = 1024 * 1024 + 65536
        consumer.messageMaxBytes = 1024 * 1024 + 65536
        producer.queueBufferingMaxMessages = 16
        producer.queueBufferingMaxKbytes = 4096
        producer.maxInFlightRequestsPerConnection = 1
        producer.messageSendMaxRetries = 0
        producer.enableIdempotence = false
        producer.acks = -1
        producer.deliveryTimeoutMs = milliseconds
        producer.messageTimeoutMs = milliseconds
        producer.shutdownFlushTimeoutMs = 1000
        producer.compressionType = KafkaConfig.CompressionType.none
        consumer.groupId = configuration.groupID
        consumer.enableAutoCommit = false
        consumer.enableAutoOffsetStore = false
        consumer.autoOffsetReset = .latest
        consumer.queuedMinMessages = 1
        consumer.queuedMaxMessagesKbytes = 1024
        consumer.fetchMessageMaxBytes = 1024 * 1024
        consumer.maxPartitionFetchBytes = 1024 * 1024
        consumer.fetchMaxBytes = 1024 * 1024 + 65536
        consumer.fetchWaitMaxMs = 100
        consumer.fetchQueueBackoffMs = 10
        consumer.enablePartitionEof = false
        return (producer, consumer)
    }
    private static func logger() -> Logger {
        Logger(label: "app.rill.kafka", factory: { _ in SwiftLogNoOpLogHandler() })
    }
    public func start(
        _ configuration: KafkaConfiguration,
        onRecord: @escaping @Sendable (StreamRecord) async -> Void
    ) async throws {
        guard task == nil, !starting else { throw BrokerError.configuration }
        starting = true
        generation = UUID()
        let id = generation
        callback = onRecord
        records = 0
        bytes = 0
        topic = configuration.topic
        do {
            let configWorker = Task.detached { try Self.configs(configuration) }
            let (producerConfig, consumerConfig) = try await withTaskCancellationHandler {
                try await configWorker.value
            } onCancel: {
                configWorker.cancel()
            }
            let metadata = try await withLogger(Self.logger()) { _ in
                try await KafkaConsumer.withConsumer(config: consumerConfig) { consumer, _, _ in
                    try await consumer.metadata(
                        topic: KafkaTopic(rawValue: configuration.topic),
                        timeout: .seconds(configuration.timeout))
                }
            }
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            guard
                let details = metadata.topics.first(where: {
                    $0.name.rawValue == configuration.topic
                }), details.error == nil,
                !details.partitions.isEmpty, details.partitions.count <= 1000
            else { throw BrokerError.protocolFailure }
            let partitions = details.partitions.filter {
                configuration.partition == nil || $0.id.rawValue == configuration.partition
            }
            guard !partitions.isEmpty, partitions.count <= 16,
                partitions.allSatisfy({ $0.error == nil && $0.leader != nil })
            else { throw BrokerError.limit }
            let (producer, producerEvents) = try withLogger(Self.logger()) { _ in
                try KafkaProducer.makeProducer(config: producerConfig)
            }
            self.producer = producer
            starting = false
            try await emit(
                StreamRecord(
                    direction: .system, kind: .open,
                    data: Data(
                        "Kafka metadata received; starting \(partitions.count) partition(s) from latest. Manual assignment; no offset commits or group balancing."
                            .utf8)), id: id)
            guard generation == id else { throw CancellationError() }
            task = Task {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await producer.run() }
                        group.addTask {
                            for await event in producerEvents {
                                if case .error = event { try await self.eventError(id) }
                            }
                        }
                        for partition in partitions {
                            var config = consumerConfig
                            config.consumptionStrategy = .partition(
                                partition.id, groupID: configuration.groupID,
                                topic: KafkaTopic(rawValue: configuration.topic), offset: .end)
                            let settings = config
                            group.addTask {
                                try await withLogger(Self.logger()) { _ in
                                    try await KafkaConsumer.withConsumer(config: settings) {
                                        _, messages, events in
                                        try await withThrowingTaskGroup(of: Void.self) { children in
                                            children.addTask {
                                                for await event in events {
                                                    if case .error = event {
                                                        try await self.eventError(id)
                                                    }
                                                }
                                            }
                                            children.addTask {
                                                for try await message in messages {
                                                    try await self.received(message, id: id)
                                                }
                                            }
                                            try await children.waitForAll()
                                        }
                                    }
                                }
                            }
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(300))
                            throw BrokerError.timeout
                        }
                        try await group.waitForAll()
                    }
                } catch {
                    if self.generation == id {
                        try? await self.emit(
                            StreamRecord(
                                direction: .system, kind: .error,
                                data: Data(
                                    "Kafka session ended: connectivity, authentication, deadline or resource failure (broker details omitted)."
                                        .utf8)), id: id)
                    }
                }
                if self.generation == id {
                    self.producer = nil
                    self.task = nil
                    self.callback = nil
                }
            }
        } catch {
            if generation == id { stop() }
            throw error
        }
    }
    public func publish(_ payload: Data, key: Data? = nil, contentType: String? = nil) async throws
    {
        guard let producer, task != nil, !publishing, payload.count <= 1024 * 1024,
            (key?.count ?? 0) <= 16384,
            contentType.map({ $0.utf8.count <= 1024 && !$0.contains("\0") }) ?? true
        else { throw BrokerError.configuration }
        publishing = true
        let id = generation
        defer { if generation == id { publishing = false } }
        let headers =
            contentType.map { [KafkaHeader(key: "content-type", value: Array($0.utf8))] } ?? []
        let message = KafkaProducer.Message(
            topic: KafkaTopic(rawValue: topic), headers: headers, key: key.map(Array.init),
            value: Array(payload))
        let report = try await producer.sendAndAwait(message)
        guard generation == id else { throw CancellationError() }
        switch report.status {
        case .acknowledged(let message):
            try await emit(
                StreamRecord(
                    direction: .outbound, kind: .text,
                    data: Data(
                        "Publish acknowledged · partition \(message.partition.rawValue) · offset \(message.offset.rawValue)"
                            .utf8)), id: id)
        case .failure: throw BrokerError.rejected(0)
        }
    }
    private func eventError(_ id: UUID) async throws {
        try await emit(
            StreamRecord(
                direction: .system, kind: .text,
                data: Data(
                    "Kafka reported an asynchronous connection/broker error; native reconnection may continue until the session deadline."
                        .utf8)), id: id)
    }
    private func received(_ message: KafkaConsumer.Message, id: UUID) async throws {
        guard message.value.count <= 1024 * 1024, (message.key?.count ?? 0) <= 16384,
            message.headers.count <= 64,
            message.headers.reduce(0, { $0 + $1.key.utf8.count + ($1.value?.count ?? 0) }) <= 16384
        else { throw BrokerError.limit }
        let contentType = message.headers.first(where: { $0.key == "content-type" })?.value.flatMap
        { String(bytes: $0, encoding: .utf8) }
        let metadata =
            "Topic: \(message.topic.rawValue) · partition \(message.partition.rawValue) · offset \(message.offset.rawValue)\nContent-Type: \(contentType ?? "(absent)")\n"
        try await emit(
            StreamRecord(
                direction: .inbound, kind: .text, data: Data(metadata.utf8) + Data(message.value)),
            id: id)
    }
    private func emit(_ record: StreamRecord, id: UUID) async throws {
        guard generation == id else { throw CancellationError() }
        let terminal = record.kind == .error || record.kind == .close
        guard records < (terminal ? 1000 : 999),
            bytes <= 8 * 1024 * 1024 - (terminal ? 0 : 1024) - record.data.count
        else { throw BrokerError.limit }
        records += 1
        bytes += record.data.count
        if let callback { await callback(record) }
    }
    public func stop() {
        generation = UUID()
        starting = false
        publishing = false
        task?.cancel()
        task = nil
        producer = nil
        callback = nil
    }
}
