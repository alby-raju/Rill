import XCTest

@testable import RillCore

final class BrunoImportTests: XCTestCase {
    private func source(
        name: String = "Example", sequence: Int = 1, method: String = "post", body: String = "none",
        auth: String = "none"
    ) -> String {
        "meta {\n  name: \(name)\n  type: http\n  seq: \(sequence)\n}\n\n\(method) {\n  url: https://example.test/api\n  body: \(body)\n  auth: \(auth)\n}\n"
    }
    private var marker: ImportFile {
        ImportFile(
            path: "API/bruno.json",
            data: Data(#"{"version":"1","name":"API","type":"collection"}"#.utf8))
    }
    func testStandaloneRawBodyAuthHeaderDisableAndDisabledSource() throws {
        let text =
            source(body: "json", auth: "basic")
            + "\nauth:basic {\n  username: user\n  password: PRIVATE_TOKEN\n}\n\nheaders {\n  ~X-Off: ignored\n}\n\nbody:json {\n  {\"a\":1}\n}\n\nscript:pre-request {\n  throw Error('NEVER_RUN');\n}\n"
        let result = try BrunoImporter.parse(
            [ImportFile(path: "request.bru", data: Data(text.utf8))], standalone: true)
        let request = result.workspace.requests[0]
        XCTAssertEqual(request.body, #"{"a":1}"#)
        XCTAssertEqual(request.auth, .basic)
        XCTAssertEqual(request.credential, "PRIVATE_TOKEN")
        XCTAssertFalse(request.headers.first { $0.name == "X-Off" }!.enabled)
        XCTAssertFalse(request.foreignScripts![0].enabled)
        XCTAssertEqual(request.foreignScripts![0].origin, "Bruno: request.bru")
        XCTAssertFalse(result.warnings.joined().contains("PRIVATE_TOKEN"))
    }
    func testBundleGroupingSequencePlainAndMarkedSecretEnvironment() throws {
        let environment =
            "vars {\n  base: https://example.test\n  token: PRIVATE_ENV\n  ~off: value\n}\n\nvars:secret [\n  token\n]\n"
        let result = try BrunoImporter.parse([
            marker,
            ImportFile(
                path: "API/Folder/later.bru", data: Data(source(name: "Later", sequence: 2).utf8)),
            ImportFile(path: "API/first.bru", data: Data(source(name: "First", sequence: 1).utf8)),
            ImportFile(path: "API/environments/Dev.bru", data: Data(environment.utf8)),
        ])
        XCTAssertEqual(result.workspace.requests.map(\.name), ["First", "Later"])
        XCTAssertTrue(result.workspace.collections.contains { $0.name == "API / Folder" })
        XCTAssertEqual(result.secretValues.values.first, "PRIVATE_ENV")
        XCTAssertFalse(result.workspace.environments[0].variables.last!.enabled)
        XCTAssertTrue(
            result.workspace.environments[0].variables[1].value.hasPrefix("{{secret:bruno-"))
    }
    func testQueryMetadataAvoidsDuplicationAndMultipartReferencesStayUnresolved() throws {
        let text =
            source(body: "multipart-form").replacingOccurrences(
                of: "https://example.test/api", with: "https://example.test/api?x=1&off=2")
            + "\nparams:query {\n  x: 1\n  ~off: 2\n}\n\nbody:multipart-form {\n  text: hello\n  file: @file(/never/read/upload.bin)\n}\n"
        let request = try BrunoImporter.parse(
            [ImportFile(path: "request.bru", data: Data(text.utf8))], standalone: true
        ).workspace.requests[0]
        XCTAssertEqual(request.url, "https://example.test/api")
        XCTAssertEqual(request.parameters.map(\.enabled), [true, false])
        XCTAssertEqual(request.multipartParts?.last?.file?.path, "/never/read/upload.bin")
        XCTAssertEqual(request.multipartParts?.last?.file?.byteCount, 0)
    }
    func testUnsupportedSyntaxScopesAuthAndBodyDisagreementReject() throws {
        for text in [
            source(auth: "inherit"), source(body: "json") + "\nbody:text {\n  wrong\n}\n",
            source() + "\nparams:path {\n  id: 1\n}\n",
            source() + "\nvars:pre-request {\n  token: x\n}\n",
            source() + "\nheaders {\nNO INDENT\n}\n",
        ] {
            XCTAssertThrowsError(
                try BrunoImporter.parse(
                    [ImportFile(path: "request.bru", data: Data(text.utf8))], standalone: true))
        }
        XCTAssertThrowsError(
            try BrunoImporter.parse(
                [ImportFile(path: "../request.bru", data: Data(source().utf8))], standalone: true))
        XCTAssertThrowsError(try BrunoImporter.parse([marker, marker]))
        XCTAssertThrowsError(
            try BrunoImporter.parse(
                [
                    ImportFile(
                        path: "env.bru",
                        data: Data(
                            "vars {\n  token: PRIVATE\n}\nvars:secret [\n  \"token\"\n]\n".utf8))
                ], standalone: true))
        XCTAssertThrowsError(
            try BrunoImporter.parse([
                marker,
                ImportFile(
                    path: "API/collection.bru",
                    data: Data("headers {\n  Authorization: private\n}\n".utf8)),
            ]))
    }
    func testExportZIPRoundTripsSupportedRawQueriesAuthAndPlainEnvironments() throws {
        var workspace = Workspace.starter
        workspace.collections[0].name = "Folder"
        workspace.requests[0].name = "Named request"
        workspace.requests[0].method = .POST
        workspace.requests[0].url = "https://example.test/api?old=%2f#fragment"
        workspace.requests[0].parameters = [Field(name: "new", value: "a +")]
        workspace.requests[0].auth = .bearer
        workspace.requests[0].credential = "PRIVATE_TOKEN"
        workspace.requests[0].bodyMode = .text
        workspace.requests[0].body = "literal\nline\n"
        workspace.requests[0].contentType = "text/plain"
        workspace.requests[0].foreignScripts = [
            ForeignScriptSource(origin: "Bruno", stage: "tests", source: "NEVER_ENABLE")
        ]
        var environment = Environment(name: "Dev")
        environment.variables = [
            Field(name: "plain", value: "value\nline"),
            Field(name: "secret", value: "{{secret:native}}"),
        ]
        workspace.environments = [environment]
        let maskedFiles = try BoundedArchive.readZIP(BrunoExporter.bundle(workspace))
        XCTAssertTrue(maskedFiles.contains { $0.path == "bruno.json" })
        XCTAssertFalse(
            maskedFiles.map { String(decoding: $0.data, as: UTF8.self) }.joined().contains(
                "PRIVATE_TOKEN"))
        XCTAssertFalse(
            maskedFiles.map { String(decoding: $0.data, as: UTF8.self) }.joined().contains(
                "NEVER_ENABLE"))
        let restored = try BrunoImporter.parse(
            BoundedArchive.readZIP(BrunoExporter.bundle(workspace, includeCredentials: true)))
        XCTAssertEqual(restored.workspace.requests[0].body, workspace.requests[0].body)
        XCTAssertEqual(restored.workspace.requests[0].credential, "PRIVATE_TOKEN")
        XCTAssertEqual(restored.workspace.environments[0].variables[0].value, "value\nline")
        XCTAssertEqual(restored.secretValues.values.first, "")
        XCTAssertEqual(
            try RequestEngine.prepare(restored.workspace.requests[0], environment: nil).url?.query,
            "old=%2F&new=a%20%2B")
    }
    func testUnsupportedFormFileExportAndCorruptZIPPreserveDestination() throws {
        var workspace = Workspace.starter
        workspace.requests[0].method = .POST
        workspace.requests[0].url = "https://example.test"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original".utf8).write(to: url)
        for mode in [RequestBodyMode.form, .multipart, .binary] {
            workspace.requests[0].bodyMode = mode
            XCTAssertThrowsError(
                try BrunoExportFile.write(BrunoExporter.bundle(workspace), to: url))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        }
        XCTAssertThrowsError(try BrunoExportFile.write(Data("not a ZIP".utf8), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }
}
