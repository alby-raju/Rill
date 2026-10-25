import XCTest

@testable import RillCore

@MainActor final class APIDefinitionTests: XCTestCase {
    func definition(
        server: String = "https://example.test", responseType: String = "string",
        summary: String = "Get pet"
    ) throws -> APIDefinition {
        let value: [String: Any] = [
            "openapi": "3.1.1", "info": ["title": "Pets"], "servers": [["url": server]],
            "paths": [
                "/pets/{id}": [
                    "get": [
                        "summary": summary, "tags": ["pets"],
                        "parameters": [
                            [
                                "name": "id", "in": "path", "required": true,
                                "schema": ["type": "integer", "default": 3],
                            ],
                            [
                                "name": "filter", "in": "query", "required": true,
                                "schema": ["type": "string", "default": "ok"],
                            ],
                        ],
                        "responses": [
                            "200": [
                                "description": "ok",
                                "content": [
                                    "application/json": [
                                        "schema": ["type": responseType], "example": "pet",
                                    ]
                                ],
                            ]
                        ],
                    ]
                ]
            ],
        ]
        return try APIDefinitionLoader.parse(
            JSONSerialization.data(withJSONObject: value), location: "pets.json")
    }
    func testGenerationAndRefreshPreviewPreserveLocalEditsAndIdentity() throws {
        let original = try definition()
        XCTAssertEqual(original.operations[0].request.url, "https://example.test/pets/3")
        XCTAssertEqual(original.operations[0].request.expectedStatus, "200")
        let imported = try APIImportPlan(original, current: Workspace()).applying(to: Workspace())
        XCTAssertEqual(imported.requests.count, 1)
        XCTAssertEqual(imported.apiDefinitions?.count, 1)
        let id = imported.requests[0].id
        let identical = try APIImportPlan(
            original, current: imported, refreshing: original.source.id)
        XCTAssertEqual(identical.changes[0].state, .unchanged)
        XCTAssertEqual(try identical.applying(to: imported).requests[0].id, id)
        let changed = try definition(summary: "Updated pet")
        let refresh = try APIImportPlan(changed, current: imported, refreshing: original.source.id)
        XCTAssertEqual(refresh.changes[0].state, .changed)
        XCTAssertEqual(try refresh.applying(to: imported).requests[0].id, id)
        var edited = imported
        edited.requests[0].bodyContains = "local"
        let preserved = try APIImportPlan(changed, current: edited, refreshing: original.source.id)
        XCTAssertEqual(preserved.changes[0].state, .locallyEdited)
        XCTAssertEqual(try preserved.applying(to: edited).requests[0].bodyContains, "local")
        XCTAssertThrowsError(try refresh.applying(to: edited))
        let config = try APIImportPlan(
            definition(server: "https://other.test"), current: imported,
            refreshing: original.source.id)
        XCTAssertEqual(config.changes[0].state, .configurationOnly)
    }
    func testYAMLBlocksAliasesSwaggerAndRejectedMergePrecision() throws {
        let yaml = """
            openapi: 3.0.4
            info: {title: YAML}
            servers: [{url: 'https://example.test'}]
            components:
              schemas:
                Text: &text
                  type: string
                  description: >
                    folded
                    text
            paths:
              /hello:
                post:
                  requestBody:
                    content:
                      application/json:
                        schema: *text
                        example: |
                          hello
                          world
                  responses:
                    '200': {description: ok}
            """
        let parsed = try APIDefinitionLoader.parse(Data(yaml.utf8), location: "api.yaml")
        XCTAssertTrue(parsed.operations[0].request.body.contains("hello\\nworld"))
        let swagger =
            ##"{"swagger":"2.0","info":{"title":"old"},"host":"example.test","basePath":"/v1","paths":{"/hello":{"get":{"responses":{"200":{"schema":{"type":"string"}}}}}}}"##
        XCTAssertEqual(
            try APIDefinitionLoader.parse(Data(swagger.utf8), location: "old.json").operations[0]
                .request.url, "https://example.test/v1/hello")
        XCTAssertThrowsError(
            try APIDefinitionLoader.parse(
                Data((yaml + "bad: {<<: *text}\n").utf8), location: "bad.yaml"))
        XCTAssertThrowsError(
            try APIDefinitionLoader.parse(
                Data((yaml + "number: 0.10000000000000001\n").utf8), location: "bad.yaml"))
    }
    func testRequestAndResponseContractsFailOnMissingOrUnsupportedValues() throws {
        let api = try definition()
        let link = APIRequestLink(
            sourceID: api.source.id, operationKey: api.operations[0].key, baseline: Data())
        let context = try XCTUnwrap(APIContractContext(link, definitions: [api.source]))
        let prepared = try RequestEngine.prepare(api.operations[0].request, environment: nil)
        XCTAssertTrue(try context.requestChecks(prepared).allSatisfy(\.passed))
        var missing = prepared
        missing.url = URL(string: "https://example.test/pets/3")
        XCTAssertFalse(try context.requestChecks(missing).allSatisfy(\.passed))
        var response = Exchange(
            requestID: UUID(), requestName: "sample", method: .GET, url: "https://example.test",
            status: 200, duration: 0,
            headers: [Field(name: "Content-Type", value: "application/json")],
            body: Data(#""pet""#.utf8), checks: [])
        XCTAssertTrue(context.responseChecks(response).allSatisfy(\.passed))
        response.body = Data("123".utf8)
        XCTAssertFalse(context.responseChecks(response).allSatisfy(\.passed))
        response.body = Data(#""pet""#.utf8)
        response.headers = []
        XCTAssertFalse(context.responseChecks(response).allSatisfy(\.passed))
        response.status = 500
        XCTAssertFalse(context.responseChecks(response).allSatisfy(\.passed))
    }
    func testNativeImportRemapsDefinitionLinksAndMarksBaselineForReview() throws {
        let api = try definition()
        let imported = try APIImportPlan(api, current: Workspace()).applying(to: Workspace())
        let remapped = try WorkspaceImport.merging(imported, into: Workspace())
        XCTAssertNotEqual(remapped.apiDefinitions?[0].id, imported.apiDefinitions?[0].id)
        XCTAssertEqual(remapped.requests[0].apiLink?.sourceID, remapped.apiDefinitions?[0].id)
        XCTAssertNoThrow(try WorkspaceFile.encode(remapped))
    }
    func testMockServerRoutesStopRestartAndContractWorkflow() async throws {
        let api = try definition()
        let routes = try DefinitionMocks.routes(api)
        XCTAssertEqual(routes[0].body, #""pet""#)
        let server = MockServer()
        let base = try await server.start(routes: routes)
        var request = api.operations[0].request
        request.url = base.absoluteString + "/pets/3"
        request.apiLink = APIRequestLink(
            sourceID: api.source.id, operationKey: api.operations[0].key, baseline: Data())
        let result = try await WorkflowEngine.execute(
            request, variables: [:], definitions: [api.source])
        XCTAssertTrue(result.passed)
        let other = MockServer()
        do {
            _ = try await other.start(routes: routes, port: UInt16(base.port!))
            XCTFail("Port conflict must fail")
        } catch {}
        await other.stop()
        await server.stop()
        let restarted = try await server.start(routes: routes)
        XCTAssertNotNil(restarted.port)
        await server.stop()
    }
    func testPassiveInspectionAndExplicitBoundedProbes() async throws {
        var response = Exchange(
            requestID: UUID(), requestName: "name", method: .GET, url: "https://example.test",
            status: 200, duration: 0,
            headers: [
                Field(name: "Content-Type", value: "text/html"),
                Field(name: "Access-Control-Allow-Origin", value: "*"),
                Field(name: "Access-Control-Allow-Credentials", value: "true"),
            ], body: Data(), checks: [])
        let findings = SecurityInspection.passive(response)
        XCTAssertTrue(
            Set(findings.map(\.rule)).isSuperset(of: ["hsts", "csp", "sniffing", "cors"]))
        response.headers += [
            Field(name: "Strict-Transport-Security", value: "max-age=31536000"),
            Field(name: "Content-Security-Policy", value: "default-src 'none'"),
            Field(name: "X-Content-Type-Options", value: "nosniff"),
        ]
        XCTAssertFalse(
            SecurityInspection.passive(response).contains {
                ["hsts", "csp", "sniffing"].contains($0.rule)
            })
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Loopback required")
        }
        let reflected = try await ActiveProbes.run(
            url: base + "/echo?value=original", method: .GET, kind: .reflection, queryName: "value")
        XCTAssertEqual(reflected.statuses, [200])
        XCTAssertTrue(reflected.findings.contains { $0.rule == "reflection" })
        let rate = try await ActiveProbes.run(
            url: base + "/json", method: .GET, kind: .rate, queryName: "", count: 2)
        XCTAssertEqual(rate.statuses.count, 2)
        do {
            _ = try await ActiveProbes.run(
                url: base, method: .POST, kind: .rate, queryName: "", count: 11)
            XCTFail("Unsafe method/count must reject")
        } catch {}
    }
    func testDefinitionApplyIsAtomicMetadataOnlyAndRejectsStaleRevision() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("workspace.json")
        let credentials = TestCredentials()
        let session = WorkspaceSession(url: url, credentials: credentials)
        let current = try await session.open()
        let api = try definition()
        let plan = try APIImportPlan(api, current: current)
        credentials.failures(write: true)
        let applied = try await session.applyAPIPlan(plan, current: current)
        XCTAssertEqual(credentials.count, 0)
        let reopened = try await WorkspaceSession(url: url, credentials: credentials).open()
        XCTAssertEqual(reopened.apiDefinitions, applied.apiDefinitions)
        XCTAssertEqual(reopened.requests.last?.apiLink, applied.requests.last?.apiLink)
        let stale = try APIImportPlan(api, current: applied, refreshing: api.source.id)
        let external = WorkspaceSession(url: url, credentials: credentials)
        var other = try await external.open()
        other.collections.append(RequestCollection(name: "external"))
        try await external.save(other)
        do {
            _ = try await session.applyAPIPlan(stale, current: applied)
            XCTFail("Stale revision must reject")
        } catch { XCTAssertEqual(error as? WorkspaceError, .conflict) }
    }
    func testRemovedEditedOperationsDetachAndAdversarialSamplesStayBounded() throws {
        let api = try definition()
        let current = try APIImportPlan(api, current: Workspace()).applying(to: Workspace())
        let empty = try APIDefinitionLoader.parse(
            Data(##"{"openapi":"3.1.1","info":{"title":"Pets"},"paths":{}}"##.utf8),
            location: "empty.json")
        let removed = try APIImportPlan(empty, current: current, refreshing: api.source.id)
            .applying(to: current)
        XCTAssertTrue(removed.requests.isEmpty)
        var edited = current
        edited.requests[0].name = "local"
        let preserved = try APIImportPlan(empty, current: edited, refreshing: api.source.id)
            .applying(to: edited)
        XCTAssertEqual(preserved.requests[0].name, "local")
        XCTAssertNil(preserved.requests[0].apiLink)
        var definitions: [String: Any] = [
            "Leaf": ["type": "string", "example": String(repeating: "x", count: 100_000)]
        ]
        for index in 0..<10 {
            definitions["N\(index)"] = [
                "type": "object",
                "properties": [
                    "a": ["$ref": "#/definitions/" + (index == 0 ? "Leaf" : "N\(index - 1)")],
                    "b": ["$ref": "#/definitions/" + (index == 0 ? "Leaf" : "N\(index - 1)")],
                ],
            ]
        }
        let root = try JSONValueParser(
            JSONSerialization.data(withJSONObject: ["definitions": definitions])
        ).parse()
        XCTAssertThrowsError(try APISamples.value(root.pointer("#/definitions/N9"), root: root))
    }
    func testMockRouteCodecValidationAndProbesNeverFollowRedirects() async throws {
        var redirect = MockRoute()
        redirect.path = "/redirect"
        redirect.status = 302
        redirect.headers = [Field(name: "Location", value: "/final")]
        redirect.body = ""
        var final = MockRoute()
        final.path = "/final"
        XCTAssertEqual(try MockRouteFile.decode(MockRouteFile.encode([redirect, final])).count, 2)
        for raw in [
            ##"[{"method":"GET","path":"/","status":200.5,"body":""}]"##,
            ##"[{"method":"GET","path":"/","status":200,"body":"","headers":{"Content-Length":"8"}}]"##,
        ] { XCTAssertThrowsError(try MockRouteFile.decode(Data(raw.utf8))) }
        let server = MockServer()
        let base = try await server.start(routes: [redirect, final])
        let report = try await ActiveProbes.run(
            url: base.absoluteString + "/redirect", method: .GET, kind: .rate, queryName: "",
            count: 2)
        XCTAssertEqual(report.statuses, [302, 302])
        await server.stop()
    }

}
