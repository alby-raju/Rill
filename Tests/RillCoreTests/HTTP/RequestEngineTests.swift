import XCTest

@testable import RillCore

final class RequestEngineTests: XCTestCase {
    func testPreparationExpandsAndEncodesQueryWithoutDroppingExistingQuery() throws {
        var environment = Environment(name: "Local")
        environment.variables = [
            Field(name: "host", value: "example.com"), Field(name: "term", value: "a & b"),
        ]
        var request = RequestDraft()
        request.url = "https://{{host}}/search?existing=1"
        request.parameters = [Field(name: "q", value: "{{term}}")]
        request.headers = [Field(name: "X-Test", value: "{{term}}")]
        let prepared = try RequestEngine.prepare(request, environment: environment)
        let items = URLComponents(url: prepared.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(
            items,
            [URLQueryItem(name: "existing", value: "1"), URLQueryItem(name: "q", value: "a & b")])
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "X-Test"), "a & b")
    }
    func testMissingVariableDoesNotSendLiteralTemplate() {
        var request = RequestDraft()
        request.url = "https://{{unknown}}/"
        XCTAssertThrowsError(try RequestEngine.prepare(request, environment: nil))
    }
    func testDisabledFieldsAndHeaderInjection() throws {
        var request = RequestDraft()
        request.url = "https://example.com"
        var disabled = Field(name: "X-Skip", value: "{{missing}}")
        disabled.enabled = false
        request.headers = [disabled]
        XCTAssertNil(
            try RequestEngine.prepare(request, environment: nil).value(forHTTPHeaderField: "X-Skip")
        )
        request.headers = [Field(name: "X-Test", value: "ok\r\nInjected: yes")]
        XCTAssertThrowsError(try RequestEngine.prepare(request, environment: nil))
    }
    func testRejectsUnsupportedSchemesAndEmbeddedCredentials() {
        for address in [
            "file:///etc/passwd", "ftp://example.com", "https://user:password@example.com",
        ] {
            var request = RequestDraft()
            request.url = address
            XCTAssertThrowsError(try RequestEngine.prepare(request, environment: nil))
        }
    }
    func testAuthBodyAndTimeout() throws {
        var request = RequestDraft()
        request.url = "https://example.com"
        request.method = .POST
        request.auth = .basic
        request.username = "name"
        request.credential = "pass"
        request.body = "{\"test\":true}"
        request.timeout = 300
        let prepared = try RequestEngine.prepare(request, environment: nil)
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "Authorization"), "Basic bmFtZTpwYXNz")
        XCTAssertEqual(prepared.httpBody, Data(request.body.utf8))
        XCTAssertEqual(prepared.timeoutInterval, 300)
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
    func testVariableReplacementWithUnicodeAndRepeatedNames() throws {
        XCTAssertEqual(
            try RequestEngine.resolve("🌊 {{ x }} / {{x}}", variables: ["x": "water"]),
            "🌊 water / water")
    }
    func testWorkspaceRoundTripAndRejectsDuplicateIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspace.json")
        var workspace = Workspace.starter
        try WorkspaceFile.save(workspace, to: file)
        let restored = try WorkspaceFile.load(from: file)
        XCTAssertEqual(restored.requests, workspace.requests)
        workspace.requests.append(workspace.requests[0])
        XCTAssertThrowsError(try WorkspaceFile.save(workspace, to: file))
        try JSONEncoder().encode(workspace).write(to: file)
        XCTAssertThrowsError(try WorkspaceFile.load(from: file))
    }
}
