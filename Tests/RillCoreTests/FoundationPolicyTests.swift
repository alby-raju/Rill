import XCTest
@testable import RillCore

final class FoundationPolicyTests: XCTestCase {
    func testDiagnosticsCannotSerializeSeededWorkspaceSecretsOrErrorText() throws {
        let secret = "SENSITIVE-SEED-never-in-report"
        var workspace = Workspace.starter
        workspace.collections[0].name = secret
        workspace.requests[0].name = secret
        workspace.requests[0].url = "https://\(secret).invalid/?token=\(secret)"
        workspace.requests[0].credential = secret
        workspace.requests[0].body = secret
        workspace.requests[0].headers = [Field(name: secret, value: secret)]
        var environment = Environment(name: secret)
        environment.variables = [Field(name: secret, value: secret)]
        workspace.environments = [environment]
        let error = NSError(domain: "untrusted", code: 42, userInfo: [NSLocalizedDescriptionKey: secret])
        let diagnostics = SupportDiagnostics(workspace: workspace, persistence: .failed, lastFailure: .classify(error))
        let data = try JSONEncoder().encode(diagnostics)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains(workspace.requests[0].id.uuidString))
        XCTAssertFalse(text.contains("https://"))
        XCTAssertEqual(diagnostics.requestCount, 1)
        XCTAssertEqual(diagnostics.lastFailure, .unknown)
    }
    func testPreviewBoundDoesNotDiscardOriginalBody() throws {
        let data = Data(repeating: 120, count: ResourceLimits.previewBytes + 20)
        let exchange = Exchange(requestID: UUID(), requestName: "Large", method: .GET, url: "http://localhost", status: 200, duration: 1, headers: [], body: data, checks: [])
        XCTAssertTrue(exchange.previewIsTruncated)
        XCTAssertEqual(exchange.previewText(pretty: true).utf8.count, ResourceLimits.previewBytes)
        XCTAssertEqual(exchange.body, data)
    }
    func testExecutionContextRejectsNavigationEditsAndEnvironmentChanges() {
        var request = RequestDraft(); request.url = "http://localhost"
        let environment = Environment(name: "Local")
        let context = ExecutionContext(request: request, environment: environment)
        var changed = request; changed.body = "Edited while sending"
        XCTAssertFalse(context.matches(request: changed, environment: environment))
        XCTAssertFalse(context.matches(request: nil, environment: environment))
        XCTAssertFalse(context.matches(request: RequestDraft(), environment: environment))
        XCTAssertFalse(context.matches(request: request, environment: Environment(name: "Other")))
        XCTAssertTrue(context.matches(request: request, environment: environment))
    }
    func testEveryHeaderProducingPathRejectsControlCharacters() throws {
        var draft = RequestDraft(); draft.url = "https://example.invalid"; draft.body = "data"
        for invalid in ["text/plain\r\nInjected: yes", "text/plain\u{0}", "text/plain\u{7f}"] {
            draft.contentType = invalid
            XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil))
        }
        draft.contentType = "text/plain"; draft.auth = .bearer; draft.credential = "token\r\nInjected: yes"
        XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil))
        draft.auth = .none
        draft.headers = [Field(name: "X-Test", value: "first"), Field(name: "x-test", value: "second")]
        XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil))
    }
    func testNonFiniteAndInvalidTimeoutsAndBudgetsAreRejected() throws {
        var draft = RequestDraft(); draft.url = "https://example.invalid"
        for invalid in [Double.nan, .infinity, -.infinity, 0, -1] {
            draft.timeout = invalid
            XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil))
        }
        XCTAssertThrowsError(try ResponseBudget(downloadBytes: 0))
        XCTAssertThrowsError(try ResponseBudget(downloadBytes: 256 * 1024 * 1024 + 1))
    }
    func testSessionHistoryDoesNotTriggerSavesButCredentialEditsDo() {
        let original = Workspace.starter
        var workspace = original
        workspace.history = [Exchange(requestID: original.requests[0].id, requestName: "History", method: .GET, url: "http://localhost", status: 200, duration: 1, headers: [], body: Data(), checks: [])]
        workspace.storageRevision = UUID()
        XCTAssertFalse(workspace.needsSave(comparedTo: original))
        workspace.requests[0].credential = "new-secret"
        XCTAssertTrue(workspace.needsSave(comparedTo: original))
    }

}
