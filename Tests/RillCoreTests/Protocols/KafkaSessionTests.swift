import Kafka
import RillBrokerTestSupport
import XCTest

@testable import RillCore

@MainActor final class KafkaSessionTests: XCTestCase {
    func testKafkaAcknowledgedPublishAndLatestConsumeOnNativeMockBroker() async throws {
        guard let fixture = RillKafkaFixtureCreate(),
            let bootstrap = RillKafkaFixtureBootstrap(fixture)
        else { return XCTFail("Native Kafka fixture failed to start") }
        defer { RillKafkaFixtureDestroy(fixture) }
        var configuration = KafkaConfiguration()
        configuration.bootstrapServers = String(cString: bootstrap)
        configuration.topic = "rill-fixture"
        configuration.security = .plaintext
        configuration.timeout = 3
        let session = KafkaSession()
        let records = LiveRecords()
        try await session.start(configuration, onRecord: { await records.add($0) })
        // Native assignment starts asynchronously; publish repeatedly until the consumer's
        // end-offset acquisition finishes. No assumption that start is an atomic cluster snapshot.
        for index in 0..<20 {
            try await session.publish(
                Data("synthetic-kafka-\(index)".utf8), contentType: CloudEvents.contentType)
            if await records.snapshot().contains(where: { $0.direction == .inbound }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<100 {
            if await records.snapshot().contains(where: { $0.direction == .inbound }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let received = await records.snapshot()
        XCTAssertTrue(
            received.contains {
                $0.direction == .outbound && $0.text.contains("Publish acknowledged")
            })
        XCTAssertTrue(
            received.contains {
                $0.direction == .inbound && $0.text.contains("synthetic-kafka-")
                    && $0.text.contains(CloudEvents.contentType)
            })
        await session.stop()
        do {
            try await session.publish(Data())
            XCTFail("Closed publisher must fail")
        } catch {}
    }
    func testKafkaConfigurationCannotCommitOrDisableTLSVerification() throws {
        var configuration = KafkaConfiguration()
        configuration.security = .plaintext
        let (producer, consumer) = try KafkaSession.configs(configuration)
        XCTAssertEqual(producer.acks, -1)
        XCTAssertEqual(producer.messageSendMaxRetries, 0)
        XCTAssertEqual(consumer.enableAutoCommit, false)
        XCTAssertEqual(consumer.enableAutoOffsetStore, false)
        XCTAssertEqual(consumer.allowAutoCreateTopics, false)
        XCTAssertEqual(producer.allowAutoCreateTopics, false)
        configuration.security = .saslTLS
        configuration.username = "synthetic"
        configuration.password = "private-test"
        let (secured, _) = try KafkaSession.configs(configuration)
        XCTAssertEqual(secured.enableSslCertificateVerification, true)
        XCTAssertEqual(secured.sslEndpointIdentificationAlgorithm, .https)
        XCTAssertEqual(secured.saslMechanism, "PLAIN")
        XCTAssertFalse(secured.sslCaPem?.isEmpty ?? true)
        configuration.topic = "^.*"
        XCTAssertThrowsError(try KafkaSession.validate(configuration))
        configuration.topic = "events"
        configuration.bootstrapServers = "user:password@localhost:9092"
        XCTAssertThrowsError(try KafkaSession.validate(configuration))
    }
}
