import XCTest
@testable import RillCore

final class HTTPSemanticsTests: XCTestCase {
    func testQueryPreservesExistingEscapesDuplicatesAndEncodesNewFields() throws {
        var draft = RequestDraft(); draft.url = "https://example.test/a%2Fb?q=%2f+%20&q=second#local"
        draft.parameters = [Field(name: "q", value: "+ /&é"), Field(name: "empty", value: "")]
        var disabled = Field(name: "ignored", value: "x"); disabled.enabled = false; draft.parameters.append(disabled)
        let request = try RequestEngine.prepare(draft, environment: nil)
        XCTAssertEqual(request.url!.absoluteString, "https://example.test/a%2Fb?q=%2f+%20&q=second&q=%2B%20%2F%26%C3%A9&empty=")
    }
    func testNoBodyAndEmptyTextAreDistinctAndLegacyStillLoads() throws {
        var draft = RequestDraft(); draft.url = "https://example.test"; draft.method = .POST
        XCTAssertNil(try RequestEngine.prepare(draft, environment: nil).httpBody)
        draft.bodyMode = .text
        XCTAssertEqual(try RequestEngine.prepare(draft, environment: nil).httpBody, Data())
        draft.body = "retained but inactive"; draft.bodyMode = RequestBodyMode.none
        XCTAssertNil(try RequestEngine.prepare(draft, environment: nil).httpBody)
        var workspace = Workspace(); workspace.requests = [draft]
        let data = try WorkspaceFile.encode(workspace)
        XCTAssertEqual(try WorkspaceFile.decode(data).requests[0], draft)
    }
    func testStructuredFormEncodesRepeatedKeysAndOverridesConflictingType() throws {
        var draft = RequestDraft(); draft.url = "https://example.test"; draft.method = .POST; draft.bodyMode = .form
        draft.formFields = [Field(name: "name", value: "a b+c"), Field(name: "name", value: "é&="), Field(name: "empty", value: "")]
        draft.headers = [Field(name: "Content-Type", value: "application/json")]
        let request = try RequestEngine.prepare(draft, environment: nil)
        XCTAssertEqual(String(data: request.httpBody!, encoding: .utf8), "name=a+b%2Bc&name=%C3%A9%26%3D&empty=")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }
    func testEveryMethodAndBodyPolicy() throws {
        for method in HTTPMethod.allCases {
            var draft = RequestDraft(); draft.url = "https://example.test"; draft.method = method
            XCTAssertEqual(try RequestEngine.prepare(draft, environment: nil).httpMethod, method.rawValue)
            draft.bodyMode = .text
            if method == .GET || method == .HEAD { XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil)) }
            else { XCTAssertEqual(try RequestEngine.prepare(draft, environment: nil).httpBody, Data()) }
        }
    }
    func testAPIKeyReplacesMatchingQueryKeysWithoutReencodingOthers() throws {
        var draft = RequestDraft(); draft.url = "https://example.test?q=%2f&token=old&%74oken=older"
        draft.auth = .apiKey; draft.apiKeyName = "token"; draft.apiKeyLocation = .query; draft.credential = "secret+ &"
        draft.parameters = [Field(name: "token", value: "ignored"), Field(name: "q", value: "added")]
        XCTAssertEqual(try RequestEngine.prepare(draft, environment: nil).url!.absoluteString, "https://example.test?q=%2f&q=added&token=secret%2B%20%26")
    }
    func testAPIKeyHeaderPrecedenceValidationAndUTF8Basic() throws {
        var draft = RequestDraft(); draft.url = "https://example.test"; draft.auth = .apiKey; draft.apiKeyName = "X-Key"; draft.credential = "new"
        draft.headers = [Field(name: "x-key", value: "old")]
        XCTAssertEqual(try RequestEngine.prepare(draft, environment: nil).value(forHTTPHeaderField: "X-Key"), "new")
        draft.credential = "bad\r\ninjected"
        XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil))
        draft.credential = "new"; draft.apiKeyName = "bad:name"
        XCTAssertThrowsError(try RequestEngine.prepare(draft, environment: nil))
        draft.auth = .basic; draft.username = "名字"; draft.credential = "пароль"
        XCTAssertEqual(try RequestEngine.prepare(draft, environment: nil).value(forHTTPHeaderField: "Authorization"), "Basic " + Data("名字:пароль".utf8).base64EncodedString())
    }
    func testPreparedSummaryMasksQueryAndCustomHeadersAndPreservesBodySize() throws {
        var draft = RequestDraft(); draft.url = "https://example.test/search?token=SEEDED_SECRET"; draft.method = .POST
        draft.body = "SEEDED_SECRET"; draft.auth = .bearer; draft.credential = "SEEDED_SECRET"; draft.headers = [Field(name: "X-Key", value: "SEEDED_SECRET")]
        let prepared = try RequestEngine.prepare(draft, environment: nil)
        let summary = PreparedRequestSummary(prepared)
        let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SEEDED_SECRET")); XCTAssertEqual(summary.bodyBytes, 13)
    }
}
