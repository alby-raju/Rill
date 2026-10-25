import XCTest
@testable import RillCore

final class HTTPieDesktopImportTests: XCTestCase {
    private func document(_ entry: [String: Any], kind: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["meta": ["format": "httpie", "version": "1.0.0", "contentType": kind], "entry": entry])
    }
    private func request(_ body: [String: Any] = ["type": "none"]) -> [String: Any] {
        ["name": "Example", "method": "POST", "url": "https://example.test/?raw=%2f", "headers": [], "queryParams": [["name": "tag", "value": "a +", "enabled": true], ["name": "off", "value": "x", "enabled": false]], "pathParams": [], "auth": ["type": "none"], "body": body]
    }
    func testWorkspaceGroupingInheritanceDraftsAndMarkedSecrets() throws {
        var inherited = request(); inherited["auth"] = ["type": "inherited"]
        let entry: [String: Any] = ["name": "Space", "collections": [["name": "API", "auth": ["type": "basic", "credentials": ["username": "user", "password": "PRIVATE_AUTH"]], "requests": [inherited]]], "drafts": [request()], "environments": [["name": "Dev", "isDefault": false, "isLocalOnly": true, "variables": [["name": "token", "value": "PRIVATE_VAR", "isSecret": true]]]]]
        let result = try HTTPieDesktopImporter.parse(document(entry, kind: "workspace"))
        XCTAssertEqual(result.workspace.requests.count, 2); XCTAssertEqual(result.workspace.collections.map(\.name), ["Space", "Space / API"])
        XCTAssertEqual(result.workspace.requests[0].auth, .basic); XCTAssertEqual(result.workspace.requests[0].credential, "PRIVATE_AUTH")
        XCTAssertEqual(result.workspace.requests[1].auth, .none)
        XCTAssertEqual(result.secretValues.values.first, "PRIVATE_VAR")
        XCTAssertTrue(result.workspace.environments[0].variables[0].value.hasPrefix("{{secret:"))
        XCTAssertFalse(result.warnings.joined().contains("PRIVATE_"))
        let prepared = try RequestEngine.prepare(result.workspace.requests[0], environment: nil)
        XCTAssertEqual(prepared.url?.absoluteString, "https://example.test/?raw=%2f&tag=a%20%2B")
    }
    func testCollectionRequestAndStandaloneEnvironmentShapes() throws {
        let collection: [String: Any] = ["name": "Collection", "auth": ["type": "none"], "requests": [request()]]
        XCTAssertEqual(try HTTPieDesktopImporter.parse(document(collection, kind: "collection")).workspace.requests.count, 1)
        let text = try HTTPieDesktopImporter.parse(document(request(["type": "text", "text": ["format": "text/yaml", "value": "a: 1"]]), kind: "request"))
        XCTAssertEqual(text.workspace.requests[0].body, "a: 1"); XCTAssertEqual(text.workspace.requests[0].contentType, "text/yaml")
        let environment: [String: Any] = ["isDefault": true, "isLocalOnly": false, "variables": [["name": "base", "value": "https://example.test", "isSecret": false]]]
        let restored = try HTTPieDesktopImporter.parse(document(environment, kind: "environment"))
        XCTAssertTrue(restored.workspace.collections.isEmpty); XCTAssertEqual(restored.workspace.environments[0].name, "Default")
    }
    func testFormFileMetadataAndBearerAPIKeyMapping() throws {
        let form = try HTTPieDesktopImporter.parse(document(request(["type": "form", "form": ["isMultipart": true, "fields": [["name": "x", "value": "v", "enabled": true, "type": "text"], ["name": "file", "file": ["name": "missing.bin"], "enabled": true, "type": "file"]]]]), kind: "request"))
        XCTAssertEqual(form.workspace.requests[0].multipartParts?.last?.file?.path, "missing.bin")
        var bearer = request(); bearer["auth"] = ["type": "bearer", "credentials": ["username": "", "password": "TOKEN"]]
        XCTAssertEqual(try HTTPieDesktopImporter.parse(document(bearer, kind: "request")).workspace.requests[0].credential, "TOKEN")
        var key = request(["type": "file", "file": ["name": "binary.dat"]]); key["auth"] = ["type": "apiKey", "target": "params", "credentials": ["username": "key", "password": "VALUE"]]
        let imported = try HTTPieDesktopImporter.parse(document(key, kind: "request")).workspace.requests[0]
        XCTAssertEqual(imported.apiKeyLocation, .query); XCTAssertEqual(imported.binaryFile?.path, "binary.dat")
    }
    func testVersionPathEscapingAndUnsupportedBodiesReject() throws {
        var path = request(); path["pathParams"] = [["name": "id", "value": "1", "enabled": true]]
        XCTAssertThrowsError(try HTTPieDesktopImporter.parse(document(path, kind: "request")))
        var escaped = request(); escaped["url"] = "https://example.test/\\{{literal}}"
        XCTAssertThrowsError(try HTTPieDesktopImporter.parse(document(escaped, kind: "request")))
        XCTAssertThrowsError(try HTTPieDesktopImporter.parse(document(request(["type": "graphql", "graphql": ["query": "query { x }", "variables": "{}"]]), kind: "request")))
        var inherited = request(); inherited["auth"] = ["type": "inherited"]
        XCTAssertThrowsError(try HTTPieDesktopImporter.parse(document(inherited, kind: "request")))
        let future = try JSONSerialization.data(withJSONObject: ["meta": ["format": "httpie", "version": "9", "contentType": "request"], "entry": request()])
        XCTAssertThrowsError(try HTTPieDesktopImporter.parse(future))
        XCTAssertThrowsError(try HTTPieDesktopImporter.parse(Data(repeating: 32, count: ResourceLimits.workspaceBytes + 1)))
    }
}
