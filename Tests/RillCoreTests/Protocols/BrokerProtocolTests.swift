import XCTest
@testable import RillCore

actor BrokerEvents {
    var messages: [BrokerMessage] = []
    var errors = 0
    func add(_ event: BrokerSessionEvent) { if case .message(let message) = event { messages.append(message) }; if case .error = event { errors += 1 } }
    func snapshot() -> [BrokerMessage] { messages }
}
actor AMQPEvents {
    var deliveries: [AMQPDelivery] = []
    func add(_ event: AMQPEvent) { if case .delivery(let value) = event { deliveries.append(value) } }
    func snapshot() -> [AMQPDelivery] { deliveries }
}
@MainActor final class BrokerProtocolTests: XCTestCase {
    func endpoint() throws -> String { guard let url = ProcessInfo.processInfo.environment["RILL_TEST_MQTT_URL"] else { throw XCTSkip("MQTT loopback fixture required") }; return url }
    func testCloudEventExactJSONAndValidation() throws {
        let body = try CloudEvents.structured(source: "/tests", type: "app.rill.synthetic", data: #"{"n":9007199254740993}"#, id: "test", time: Date(timeIntervalSince1970: 0))
        let value = try JSONValueParser(body).parse()
        XCTAssertEqual(value["specversion"]?.string, "1.0"); XCTAssertEqual(value["data"]?["n"], .number("9007199254740993e0"))
        XCTAssertEqual(value["time"]?.string, "1970-01-01T00:00:00.000Z")
        XCTAssertThrowsError(try CloudEvents.structured(source: "/ok", type: "event", data: "{}", time: Date(timeIntervalSince1970: 1e300)))
        XCTAssertThrowsError(try CloudEvents.structured(source: "bad source", type: "event", data: "{}"))
        XCTAssertThrowsError(try CloudEvents.structured(source: "/ok", type: "event\n", data: "{}"))
        XCTAssertThrowsError(try CloudEvents.structured(source: "/ok", type: "event", data: #"{"x":1,"x":2}"#))
    }
    func testMQTTIncrementalLengthsTopicsAndMalformedProperties() throws {
        let packet = try MQTTEncoding.packet(0x30, Data(repeating: 42, count: 16384))
        var parser = MQTTDecoder(), result: [MQTTPacket] = []
        for byte in packet { result += try parser.append(Data([byte])) }
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.body.count, 16384)
        var malformed = MQTTDecoder(); XCTAssertThrowsError(try malformed.append(Data([0x30, 0x80, 0])))
        XCTAssertTrue(MQTTEncoding.topic("events/+/updated/#", subscription: true))
        XCTAssertFalse(MQTTEncoding.topic("events/#/next", subscription: true)); XCTAssertFalse(MQTTEncoding.topic("events/+", subscription: false))
        var properties = MQTTReader(data: Data([1, 255])); XCTAssertThrowsError(try properties.properties())
    }
    func testMQTTBothVersionsQoSRetainAndAcknowledgedEcho() async throws {
        let endpoint = try endpoint()
        for version in MQTTVersion.allCases {
            let client = MQTTClient(), events = BrokerEvents()
            var configuration = MQTTConfiguration(); configuration.endpoint = endpoint; configuration.version = version; configuration.timeout = 2
            try await client.connect(configuration, onEvent: { await events.add($0) })
            try await client.subscribe("events/+", qos: .exactlyOnce)
            for qos in MQTTQoS.allCases {
                let payload = Data("synthetic 🐟 QoS \(qos.rawValue)".utf8)
                try await client.publish(topic: "events/concrete", payload: payload, qos: qos, retain: true, contentType: version == .v5 ? "text/plain" : nil, payloadIsUTF8: true)
            }
            for _ in 0..<200 { if await events.snapshot().count == 3 { break }; try await Task.sleep(for: .milliseconds(10)) }
            let messages = await events.snapshot()
            XCTAssertEqual(messages.map(\.qos), MQTTQoS.allCases); XCTAssertTrue(messages.allSatisfy(\.retained))
            XCTAssertEqual(messages.first?.destination, "events/concrete")
            if version == .v5 { XCTAssertTrue(messages.allSatisfy { $0.contentType == "text/plain" }) }
            do { try await client.subscribe("reject/#"); XCTFail("Rejected subscription must fail") } catch { XCTAssertTrue(error is BrokerError) }
            do { try await client.publish(topic: "events/+", payload: Data()); XCTFail("Wildcard publish must reject") } catch { }
            await client.stop()
            do { try await client.publish(topic: "events/concrete", payload: Data()); XCTFail("Closed client must reject") } catch { }
        }
    }
    func testMQTTOverFragmentedWebSocketPreservesPathAndMetadata() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_LIVE_URL"] else { throw XCTSkip("Live fixture required") }
        let client = MQTTClient(), events = BrokerEvents()
        var configuration = MQTTConfiguration(); configuration.endpoint = base.replacingOccurrences(of: "http://", with: "ws://") + "/mqtt?fixture=preserved"; configuration.timeout = 2
        try await client.connect(configuration, onEvent: { await events.add($0) })
        try await client.subscribe("events/#", qos: .exactlyOnce)
        let payload = try CloudEvents.structured(source: "/tests", type: "app.rill.test", data: "{\"ok\":true}")
        try await client.publish(topic: "events/concrete", payload: payload, qos: .exactlyOnce, contentType: CloudEvents.contentType, payloadIsUTF8: true)
        for _ in 0..<200 { if await events.snapshot().count == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let message = await events.snapshot().first
        XCTAssertEqual(message?.payload, payload); XCTAssertEqual(message?.contentType, CloudEvents.contentType)
        await client.stop()
    }
    func testAMQPExistingQueueConfirmedPublishAndAcknowledgedDelivery() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["RILL_TEST_AMQP_URL"] else { throw XCTSkip("AMQP fixture required") }
        let client = AMQPClient(), events = AMQPEvents()
        var configuration = AMQPConfiguration(); configuration.endpoint = endpoint; configuration.timeout = 2
        try await client.connect(configuration, onEvent: { await events.add($0) })
        try await client.consume(queue: "existing")
        let body = Data(repeating: 42, count: 200000)
        try await client.publish(queue: "existing", payload: body, contentType: "application/octet-stream")
        try await client.publish(queue: "existing", payload: Data(), contentType: CloudEvents.contentType)
        for _ in 0..<200 { if await events.snapshot().count == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let deliveries = await events.snapshot()
        XCTAssertEqual(deliveries.map(\.payload), [body, Data()]); XCTAssertEqual(deliveries.first?.routingKey, "existing")
        XCTAssertEqual(deliveries.first?.contentType, "application/octet-stream"); XCTAssertEqual(deliveries.last?.contentType, CloudEvents.contentType)
        do { try await client.publish(queue: "missing", payload: Data("unroutable".utf8)); XCTFail("Mandatory returned publish must fail") } catch { XCTAssertTrue(error is BrokerError) }
        await client.stop()
    }
    func testAMQPRefusesMissingQueueAndCredentialsAndMalformedFrames() async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["RILL_TEST_AMQP_URL"] else { throw XCTSkip("AMQP fixture required") }
        let client = AMQPClient(); var configuration = AMQPConfiguration(); configuration.endpoint = endpoint; configuration.timeout = 2
        configuration.password = "reject"
        do { try await client.connect(configuration, onEvent: { _ in }); XCTFail("Auth rejection must fail") } catch { }
        configuration.password = ""
        try await client.connect(configuration, onEvent: { _ in })
        do { try await client.consume(queue: "missing"); XCTFail("No topology creation fallback") } catch { }
        await client.stop()
        var parser = AMQPDecoder()
        let bytes = try AMQPEncoding.frame(3, channel: 1, payload: Data([0,255]))
        var frames: [AMQPFrame] = []
        for byte in bytes { frames += try parser.append(Data([byte])) }
        XCTAssertEqual(frames.first?.payload, Data([0,255]))
        var bad = bytes; bad[bad.count-1] = 0; var rejected = AMQPDecoder()
        XCTAssertThrowsError(try rejected.append(bad))
    }
    func testMQTTConnectionRefusalDeadlineAndCancellation() async throws {
        let endpoint = try endpoint(), client = MQTTClient()
        var configuration = MQTTConfiguration(); configuration.endpoint = endpoint; configuration.clientID = "reject"; configuration.timeout = 1
        do { try await client.connect(configuration, onEvent: { _ in }); XCTFail("Broker rejection must fail") } catch { XCTAssertTrue(error is BrokerError) }
        configuration.clientID = "stall"
        let stalled = configuration
        let task = Task { try await client.connect(stalled, onEvent: { _ in }) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { try await task.value; XCTFail("Cancel must stop pending connect") } catch { }
        configuration.clientID = "valid"
        try await client.connect(configuration, onEvent: { _ in }); await client.stop()
    }
}
