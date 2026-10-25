import XCTest

@testable import RillCore

final class ForeignExportTests: XCTestCase {
    func testPostmanCollectionRoundTripsFieldsFragmentsAndAuthMasking() throws {
        var workspace = Workspace.starter
        var draft = workspace.requests[0]
        draft.name = "Quotes \" and Unicode 日本"
        draft.url = "https://example.test/?old=%2f#fragment"
        draft.method = .PATCH
        draft.parameters = [Field(name: "new", value: "a +")]
        var off = Field(name: "off", value: "x")
        off.enabled = false
        draft.parameters.append(off)
        draft.auth = .basic
        draft.username = "user"
        draft.credential = "PRIVATE_AUTH"
        draft.headers = [Field(name: "Cookie", value: "PRIVATE_COOKIE")]
        draft.bodyMode = .text
        draft.body = "literal\n'$value'"
        draft.contentType = "text/plain"
        workspace.requests = [draft]
        let masked = try PostmanImporter.parse(PostmanExporter.collection(workspace)).workspace
            .requests[0]
        XCTAssertEqual(masked.credential, "[REDACTED]")
        XCTAssertEqual(masked.headers[0].value, "[REDACTED]")
        let imported = try PostmanImporter.parse(
            PostmanExporter.collection(workspace, includeCredentials: true)
        ).workspace.requests[0]
        XCTAssertEqual(imported.name, draft.name)
        XCTAssertEqual(imported.body, draft.body)
        XCTAssertEqual(imported.credential, draft.credential)
        let first = try RequestEngine.prepare(draft, environment: nil)
        let second = try RequestEngine.prepare(imported, environment: nil)
        XCTAssertEqual(
            second.url?.query, first.url?.query?.replacingOccurrences(of: "%2f", with: "%2F"))
        XCTAssertEqual(first.httpBody, second.httpBody)
        XCTAssertEqual(
            first.value(forHTTPHeaderField: "Content-Type"),
            second.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(imported.parameters.last?.enabled, false)
    }
    func testPostmanFormMultipartBinaryMetadataAndEnvironmentSecretOmission() throws {
        var workspace = Workspace.starter
        workspace.requests = []
        for mode in [RequestBodyMode.form, .multipart, .binary] {
            var draft = RequestDraft(collectionID: workspace.collections[0].id)
            draft.method = .POST
            draft.url = "https://example.test"
            draft.bodyMode = mode
            draft.formFields = [Field(name: "x", value: "1"), Field(name: "x", value: "2")]
            var part = MultipartPart()
            part.name = "file"
            part.kind = .file
            part.file = try CommandImporter.reference("/never/read/file.bin")
            part.filename = "file.bin"
            part.contentType = "application/octet-stream"
            draft.multipartParts = [part]
            draft.binaryFile = try CommandImporter.reference("/never/read/file.bin")
            draft.contentType = "application/octet-stream"
            workspace.requests.append(draft)
        }
        let result = try PostmanImporter.parse(PostmanExporter.collection(workspace)).workspace
        XCTAssertEqual(result.requests.map(\.bodyMode), [.form, .multipart, .binary])
        XCTAssertEqual(result.requests[0].formFields?.map(\.value), ["1", "2"])
        XCTAssertEqual(result.requests[1].multipartParts?.first?.file?.path, "/never/read/file.bin")
        XCTAssertEqual(result.requests[2].contentType, "application/octet-stream")
        var environment = Environment(name: "Dev")
        environment.variables = [
            Field(name: "token", value: "{{ secret:token }}"),
            Field(name: "base", value: "https://example.test"),
        ]
        let encoded = try PostmanExporter.environment(environment)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret:token"))
        let restored = try PostmanImporter.parse(encoded)
        XCTAssertEqual(restored.secretValues.values.first, "")
        XCTAssertEqual(
            restored.workspace.environments[0].variables[1].value, "https://example.test")
    }
    func testHARExplicitPlaceholderAndMaskedOrIncludedFrozenValues() throws {
        var draft = RequestDraft()
        draft.url = "{{base}}/api?token=PRIVATE_QUERY"
        draft.method = .POST
        draft.auth = .apiKey
        draft.apiKeyName = "X-Custom-Secret"
        draft.apiKeyLocation = .header
        draft.credential = "PRIVATE_KEY"
        draft.bodyMode = .text
        draft.body = "payload"
        draft.contentType = "text/plain"
        var environment = Environment(name: "Dev")
        environment.variables = [Field(name: "base", value: "https://example.test")]
        let masked = try HARExporter.request(
            draft, environment: environment, exportedAt: Date(timeIntervalSince1970: 0))
        let text = String(decoding: masked, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_QUERY"))
        XCTAssertFalse(text.contains("PRIVATE_KEY"))
        XCTAssertTrue(text.contains("UNEXECUTED"))
        let root = try JSONSerialization.jsonObject(with: masked) as! [String: Any]
        let log = root["log"] as! [String: Any]
        let entry = (log["entries"] as! [[String: Any]])[0]
        XCTAssertEqual((entry["response"] as! [String: Any])["status"] as? Int, 0)
        XCTAssertEqual(entry["startedDateTime"] as? String, "1970-01-01T00:00:00Z")
        let included = try HARExporter.request(
            draft, environment: environment, includeCredentials: true)
        let imported = try HARImporter.parse(included)[0].request
        XCTAssertEqual(imported.body, "payload")
        XCTAssertEqual(imported.url, "https://example.test/api?token=PRIVATE_QUERY")
        XCTAssertEqual(
            imported.headers.first { $0.name.lowercased() == "x-custom-secret" }?.value,
            "PRIVATE_KEY")
    }
    func testUnsupportedExportsThrowBeforeDestinationIsTouched() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original".utf8).write(to: url)
        var workspace = Workspace.starter
        workspace.requests[0].authProfileID = UUID()
        XCTAssertThrowsError(
            try ForeignExportFile.write(PostmanExporter.collection(workspace), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        var draft = RequestDraft()
        draft.url = "https://example.test"
        draft.method = .POST
        draft.bodyMode = .binary
        XCTAssertThrowsError(try HARExporter.request(draft, environment: nil))
        draft.bodyMode = .text
        draft.body = String(repeating: "x", count: 1024 * 1024 + 1)
        XCTAssertThrowsError(try HARExporter.request(draft, environment: nil))
    }
}
