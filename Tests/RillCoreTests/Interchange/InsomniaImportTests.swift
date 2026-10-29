import XCTest

@testable import RillCore

final class InsomniaImportTests: XCTestCase {
    private func legacy(_ resources: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["__export_format": 4, "resources": resources])
    }
    private var workspace: [String: Any] {
        ["_id": "__WORKSPACE_ID__", "_type": "workspace", "name": "API"]
    }
    private func request(_ id: String = "req_1", parent: String = "__WORKSPACE_ID__") -> [String:
        Any]
    {
        [
            "_id": id, "_type": "request", "parentId": parent, "name": "Example", "method": "POST",
            "url": "https://example.test/?raw=%2f", "headers": [],
            "parameters": [["name": "tag", "value": "a +", "disabled": false]],
        ]
    }
    func testLegacyResourceFoldersEnvironmentInheritanceAndAuth() throws {
        let folder: [String: Any] = [
            "_id": "fld_1", "_type": "request_group", "parentId": "__WORKSPACE_ID__",
            "name": "Folder", "authentication": ["type": "bearer", "token": "PRIVATE_AUTH"],
        ]
        let base: [String: Any] = [
            "_id": "__BASE_ENVIRONMENT_ID__", "_type": "environment",
            "parentId": "__WORKSPACE_ID__", "name": "Base",
            "data": ["base": "https://example.test"],
        ]
        let child: [String: Any] = [
            "_id": "env_1", "_type": "environment", "parentId": "__BASE_ENVIRONMENT_ID__",
            "name": "Dev", "data": ["token": "PRIVATE_ENV"], "confidentialKeys": ["token"],
        ]
        let result = try InsomniaImporter.parse(
            legacy([workspace, folder, request(parent: "fld_1"), base, child]))
        XCTAssertEqual(result.workspace.collections.map(\.name), ["API / Folder"])
        XCTAssertEqual(result.workspace.requests[0].credential, "PRIVATE_AUTH")
        XCTAssertEqual(result.workspace.requests[0].auth, .bearer)
        XCTAssertEqual(
            result.workspace.environments[1].parentID, result.workspace.environments[0].id)
        XCTAssertEqual(result.secretValues.values.first, "PRIVATE_ENV")
        XCTAssertFalse(result.warnings.joined().contains("PRIVATE_"))
        XCTAssertEqual(
            try RequestEngine.prepare(result.workspace.requests[0], environment: nil).url?
                .absoluteString, "https://example.test/?raw=%2f&tag=a%20%2B")
    }
    func testYAMLTemplatesScriptsRemainDisabledAndSurviveNativeStorageAndDuplication() throws {
        let yaml = """
            type: collection.insomnia.rest/5.0
            schema_version: "5.1"
            name: API
            collection:
              - name: Folder
                scripts:
                  preRequest: "console.log('independently authored fixture');"
                children:
                  - name: Example
                    method: POST
                    url: "{{ _.base }}/api"
                    body:
                      mimeType: application/json
                      text: '{"a":1}'
                    scripts:
                      afterResponse: "throw Error('never execute');"
            environments:
              name: Base
              data:
                base: https://example.test
            """
        let parsed = try InsomniaImporter.parse(Data(yaml.utf8))
        let draft = parsed.workspace.requests[0]
        XCTAssertEqual(draft.url, "{{base}}/api")
        XCTAssertEqual(draft.foreignScripts?.count, 2)
        XCTAssertTrue(draft.foreignScripts!.allSatisfy { !$0.enabled })
        let restored = try WorkspaceFile.decode(WorkspaceFile.encode(parsed.workspace))
        XCTAssertEqual(restored.requests[0].foreignScripts, draft.foreignScripts)
        let merged = try WorkspaceImport.merging(restored, into: Workspace())
        XCTAssertEqual(merged.requests[0].foreignScripts, draft.foreignScripts)
        XCTAssertEqual(draft.body, #"{"a":1}"#)
    }
    func testSupportedAuthAndRawFormFileBodyFamilies() throws {
        var basic = request("req_basic")
        basic["authentication"] = ["type": "basic", "username": "user", "password": "pass"]
        basic["body"] = ["mimeType": "text/plain", "text": "literal"]
        var form = request("req_form")
        form["body"] = [
            "mimeType": "application/x-www-form-urlencoded",
            "params": [
                ["name": "x", "value": "1"], ["name": "x", "value": "2", "disabled": true],
            ],
        ]
        var multipart = request("req_multipart")
        multipart["body"] = [
            "mimeType": "multipart/form-data",
            "params": [["name": "upload", "type": "file", "fileName": "/never/read/file"]],
        ]
        var binary = request("req_binary")
        binary["body"] = ["mimeType": "application/octet-stream", "fileName": "/never/read/binary"]
        binary["authentication"] = [
            "type": "apikey", "key": "api", "value": "secret", "addTo": "queryParams",
        ]
        let result = try InsomniaImporter.parse(
            legacy([workspace, basic, form, multipart, binary])
        ).workspace.requests
        XCTAssertEqual(result.map(\.bodyMode), [.text, .form, .multipart, .binary])
        XCTAssertEqual(result[0].auth, .basic)
        XCTAssertEqual(result[1].formFields?.map(\.enabled), [true, false])
        XCTAssertEqual(result[2].multipartParts?.first?.file?.path, "/never/read/file")
        XCTAssertEqual(result[3].apiKeyLocation, .query)
    }
    func testUnsupportedTemplatesResourcesAuthAndDanglingParentsFail() throws {
        var missing = request()
        missing["parentId"] = "missing"
        XCTAssertThrowsError(try InsomniaImporter.parse(legacy([workspace, missing])))
        for value in ["{{    _.nested.value }}", "{% dynamic 'value' %}", "\\{{escaped}}"] {
            var draft = request()
            draft["url"] = value
            XCTAssertThrowsError(try InsomniaImporter.parse(legacy([workspace, draft])))
        }
        var rawMultipart = request()
        rawMultipart["body"] = [
            "mimeType": "multipart/form-data", "text": "captured boundary payload",
        ]
        XCTAssertThrowsError(try InsomniaImporter.parse(legacy([workspace, rawMultipart])))
        var malformedScript = request()
        malformedScript["scripts"] = "malformed"
        XCTAssertThrowsError(try InsomniaImporter.parse(legacy([workspace, malformedScript])))
        var oauth = request()
        oauth["authentication"] = ["type": "oauth2"]
        XCTAssertThrowsError(try InsomniaImporter.parse(legacy([workspace, oauth])))
        var grpc = request()
        grpc["_type"] = "grpc_request"
        XCTAssertThrowsError(try InsomniaImporter.parse(legacy([workspace, grpc])))
        var duplicate = request()
        duplicate["_id"] = "__WORKSPACE_ID__"
        XCTAssertThrowsError(try InsomniaImporter.parse(legacy([workspace, duplicate])))
    }
    func testKVEnvironmentSecretAndDisabledFields() throws {
        let yaml = """
            type: environment.insomnia.rest/5.0
            environments:
              name: Private
              environmentType: kv
              kvPairData:
                - id: a
                  name: token
                  value: PRIVATE_VALUE
                  type: secret
                  enabled: true
                - id: b
                  name: off
                  value: v
                  type: str
                  enabled: false
            """
        let result = try InsomniaImporter.parse(Data(yaml.utf8))
        XCTAssertEqual(result.secretValues.values.first, "PRIVATE_VALUE")
        XCTAssertFalse(result.workspace.environments[0].variables[1].enabled)
        XCTAssertFalse(
            String(decoding: try WorkspaceFile.encode(result.workspace), as: UTF8.self).contains(
                "PRIVATE_VALUE"))
    }
    func testYAMLExportRoundTripMasksCredentialsAndOmitsExecutableScripts() throws {
        var source = Workspace.starter
        source.requests[0].url = "https://example.test"
        source.requests[0].method = .POST
        source.requests[0].auth = .bearer
        source.requests[0].credential = "PRIVATE_TOKEN"
        source.requests[0].bodyMode = .text
        source.requests[0].body = "yes\nUnicode 日本"
        source.requests[0].contentType = "text/plain"
        source.requests[0].foreignScripts = [
            ForeignScriptSource(
                origin: "Insomnia", stage: "preRequest", source: "throw Error('NEVER_ENABLE');")
        ]
        var environment = Environment(name: "Dev")
        environment.variables = [Field(name: "token", value: "{{secret:token}}")]
        let masked = try InsomniaExporter.collection(source, environment: environment)
        let text = String(decoding: masked, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_TOKEN"))
        XCTAssertFalse(text.contains("NEVER_ENABLE"))
        XCTAssertFalse(text.contains("{{secret:token}}"))
        let imported = try InsomniaImporter.parse(masked)
        XCTAssertEqual(imported.workspace.requests[0].credential, "[REDACTED]")
        XCTAssertNil(imported.workspace.requests[0].foreignScripts)
        XCTAssertEqual(imported.workspace.requests[0].body, source.requests[0].body)
        let included = try InsomniaImporter.parse(
            InsomniaExporter.collection(source, environment: nil, includeCredentials: true))
        XCTAssertEqual(included.workspace.requests[0].credential, "PRIVATE_TOKEN")
    }
    func testForeignScriptBoundsAndUnrepresentableExportPreserveDestination() throws {
        var workspace = Workspace.starter
        workspace.requests[0].url = "https://example.test"
        workspace.requests[0].foreignScripts = [
            ForeignScriptSource(
                origin: "Insomnia", stage: "preRequest",
                source: String(repeating: "x", count: 256 * 1024 + 1))
        ]
        XCTAssertThrowsError(try WorkspaceFile.encode(workspace))
        workspace.requests[0].foreignScripts = nil
        workspace.requests[0].tlsProfileID = UUID()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original".utf8).write(to: url)
        XCTAssertThrowsError(
            try InsomniaExportFile.write(
                InsomniaExporter.collection(workspace, environment: nil), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }
}
