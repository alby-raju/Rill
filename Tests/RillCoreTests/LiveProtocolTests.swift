import XCTest
@testable import RillCore

actor LiveRecords {
    private var records: [StreamRecord] = []
    func add(_ record: StreamRecord) { records.append(record) }
    func snapshot() -> [StreamRecord] { records }
}
actor LiveEvents {
    private var values: [ServerEvent] = []
    func add(_ event: ServerEvent) { values.append(event) }
    func snapshot() -> [ServerEvent] { values }
}
@MainActor final class LiveProtocolTests: XCTestCase {
    func base() throws -> String { guard let value = ProcessInfo.processInfo.environment["RILL_TEST_LIVE_URL"] else { throw XCTSkip("Live loopback fixture required") }; return value }
    func testGraphQLPayloadEscapesAndPreservesExactVariables() throws {
        var configuration = GraphQLConfiguration(); configuration.query = "query { field(arg: \"quoted\\value\") }"; configuration.variables = #"{"n":9007199254740993,"name":"🐟"}"#
        let body = try GraphQL.body(configuration)
        let value = try JSONValueParser(body).parse()
        XCTAssertEqual(value["variables"]?["n"], .number("9007199254740993e0"))
        XCTAssertEqual(value["query"]?.string, configuration.query)
        configuration.variables = "[]"; XCTAssertThrowsError(try GraphQL.body(configuration))
        configuration.variables = "{}"; configuration.operationName = "invalid name"; XCTAssertThrowsError(try GraphQL.body(configuration))
        configuration.query = ""; XCTAssertNoThrow(try GraphQL.validateStorage(configuration)); XCTAssertThrowsError(try GraphQL.validate(configuration))
    }
    func testGraphQLForeignCollectionsRefuseLossyExport() throws {
        var request = RequestDraft(); request.url = "https://example.com/graphql"; request.method = .POST; request.graphql = GraphQLConfiguration()
        var workspace = Workspace(); workspace.requests = [request]
        XCTAssertThrowsError(try PostmanExporter.collection(workspace))
        XCTAssertThrowsError(try InsomniaExporter.collection(workspace, environment: nil))
        XCTAssertThrowsError(try BrunoExporter.bundle(workspace))
        let native = try JSONEncoder().encode(workspace)
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: native).requests.first?.graphql, request.graphql)
    }
    func testGraphQLHTTPAndIntrospectionAreExplicitAndOfflineReloadWorks() async throws {
        let base = try base()
        var draft = RequestDraft(); draft.url = base + "/graphql"; draft.method = .POST; draft.graphql = GraphQLConfiguration(); draft.graphql?.variables = #"{"name":"hello"}"#
        let response = try await RequestEngine.execute(draft, environment: nil)
        XCTAssertTrue(response.checks.allSatisfy(\.passed)); XCTAssertTrue(response.text.contains("hello"))
        let snapshot = try await GraphQL.introspect(draft, environment: nil)
        let schema = try GraphQLSchema(snapshot)
        XCTAssertEqual(schema.completions(prefix: "he"), ["hello"]); XCTAssertTrue(schema.names.contains("recipient"))
        draft.url = base + "/graphql-errors"
        let errors = try await RequestEngine.execute(draft, environment: nil)
        XCTAssertEqual(errors.status, 200); XCTAssertFalse(errors.checks.allSatisfy(\.passed))
        XCTAssertEqual(try GraphQL.result(errors.body).errors, ["Synthetic GraphQL error"])
        draft.url = base + "/graphql-disabled"
        do { _ = try await GraphQL.introspect(draft, environment: nil); XCTFail("Disabled introspection should fail") } catch { XCTAssertTrue(error is GraphQLError) }
    }
    func testSSEParserMixedLinesBOMIDsAndBounds() throws {
        var parser = ServerEventParser(), events: [ServerEvent] = []
        let source = "\u{FEFF}id: one\r\nevent: update\rdata: first\r\ndata: 🐟\nretry: 123\n\nid:\ndata: second\n\n"
        for byte in source.utf8 { if let event = try parser.append(byte) { events.append(event) } }
        XCTAssertEqual(events.map(\.data), ["first\n🐟", "second"])
        XCTAssertEqual(events.map(\.event), ["update", "message"])
        XCTAssertEqual(events.map(\.identifier), ["one", ""]); XCTAssertEqual(events[0].retryMilliseconds, 123)
        var tooLong = ServerEventParser()
        XCTAssertThrowsError(try Data(repeating: 97, count: 65537).forEach { _ = try tooLong.append($0) })
    }
    func testSSEStreamingAndStalledCancellation() async throws {
        let base = try base(), events = LiveEvents()
        var request = RequestDraft(); request.url = base + "/sse"
        try await ServerSentEvents.run(request, environment: nil, onEvent: { await events.add($0) })
        let received = await events.snapshot(); XCTAssertEqual(received.map(\.data), ["hello\n🐟", "second"])
        request.url = base + "/sse-stall"; let snapshot = request
        let task = Task { try await ServerSentEvents.run(snapshot, environment: nil, onEvent: { _ in }) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { try await task.value; XCTFail("Cancelled stream should stop") } catch { }
        request.url = base + "/sse-bad"
        do { try await ServerSentEvents.run(request, environment: nil, onEvent: { _ in }); XCTFail("Wrong MIME must fail") } catch { XCTAssertTrue(error is StreamError) }
    }
    func testWebSocketTextBinaryFragmentationPingAndDisconnect() async throws {
        let base = try base().replacingOccurrences(of: "http://", with: "ws://"), client = WebSocketClient(), records = LiveRecords()
        var request = RequestDraft(); request.url = base + "/ws"; request.timeout = 2
        try await client.connect(request, environment: nil, onRecord: { await records.add($0) })
        try await client.send(text: "literal 🐟 $HOME")
        try await client.send(data: Data([0, 255, 42]))
        try await client.ping()
        for _ in 0..<100 {
            if await records.snapshot().filter({ $0.direction == .inbound }).count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let received = await records.snapshot().filter { $0.direction == .inbound }
        XCTAssertTrue(received.contains { $0.kind == .text && $0.text == "fragmented" })
        XCTAssertTrue(received.contains { $0.kind == .text && $0.text == "literal 🐟 $HOME" })
        XCTAssertTrue(received.contains { $0.kind == .binary && $0.data == Data([0, 255, 42]) })
        do { try await client.send(data: Data(repeating: 1, count: 1024 * 1024 + 1)); XCTFail("Oversized message must fail") } catch { XCTAssertTrue(error is WorkflowError) }
        await client.stop()
        do { try await client.send(text: "closed"); XCTFail("Closed send must fail") } catch { XCTAssertTrue(error is StreamError) }
    }
    func testSubscriptionNegotiatesAckPingNextCompleteAndMasksInit() async throws {
        let base = try base().replacingOccurrences(of: "http://", with: "ws://"), client = GraphQLSubscriptionClient(), records = LiveRecords()
        var request = RequestDraft(); request.url = base + "/subscription"; request.graphql = GraphQLConfiguration(); request.graphql?.query = "subscription { value }"; request.timeout = 2
        try await client.start(request, environment: nil, initPayload: #"{"token":"synthetic-private"}"#, onRecord: { await records.add($0) })
        for _ in 0..<100 {
            if await records.snapshot().contains(where: { $0.kind == .close }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let received = await records.snapshot()
        XCTAssertTrue(received.contains { $0.text.contains("connection_ack") })
        XCTAssertTrue(received.contains { $0.text.contains("\"next\"") })
        XCTAssertTrue(received.contains { $0.kind == .close })
        XCTAssertFalse(received.contains { $0.text.contains("synthetic-private") })
        await client.stop()
        request.url = base + "/subscription-no-ack"; request.timeout = 1
        do { try await client.start(request, environment: nil, onRecord: { _ in }); XCTFail("Ack timeout must fail") } catch { }
        await client.stop()
    }
    func testImportedGraphQLNeverEnablesAutomaticIntrospection() throws {
        var workspace = Workspace.starter; workspace.requests[0].method = .POST; workspace.requests[0].graphql = GraphQLConfiguration(); workspace.requests[0].graphql?.introspectOnEndpointChange = true
        let imported = try WorkspaceImport.merging(workspace, into: Workspace())
        XCTAssertEqual(imported.requests[0].graphql?.introspectOnEndpointChange, false)
    }
}
