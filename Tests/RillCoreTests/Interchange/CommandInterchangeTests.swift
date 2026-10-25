import XCTest

@testable import RillCore

@MainActor final class CommandInterchangeTests: XCTestCase {
    func testLexerRoundTripsLiteralQuotesDollarSignsBackticksAndNewlines() throws {
        for value in [
            "", "a'b\"c", "$HOME $(touch never) `command`", "line\nline\r\nline",
            "\\path with spaces",
        ] {
            XCTAssertEqual(
                try CommandWords.parse("curl " + CommandWords.quote(value)), ["curl", value])
        }
        XCTAssertEqual(
            try CommandWords.parse("curl \\\n 'https://example.test'"),
            ["curl", "https://example.test"])
        XCTAssertEqual(
            try CommandWords.parse(
                "curl https://example.test" + String(repeating: "\n", count: 20_000)),
            ["curl", "https://example.test"])
    }
    func testLexerRejectsShellExecutionListsSubstitutionAndUnbalancedQuotes() {
        for command in [
            "curl x; touch marker", "curl x | sh", "curl x > file", "curl x && echo bad",
            "curl $(cat secret)", "curl \"$TOKEN\"", "curl `command`", "curl 'unterminated",
            "curl x\ncurl y",
        ] {
            XCTAssertThrowsError(try CommandWords.parse(command), command)
        }
    }
    func testCurlRawJSONHeaderAuthAndTimeout() throws {
        let imported = try CommandImporter.parse(
            #"curl -sSL -XPOST 'https://example.test/path?q=%2f' -H 'Content-Type: application/json' -H 'Authorization: Bearer token' --data-raw '{"value":"a&b"}' --max-time 12"#
        )
        XCTAssertEqual(imported.request.method, .POST)
        XCTAssertEqual(imported.request.timeout, 12)
        XCTAssertEqual(imported.request.auth, .bearer)
        XCTAssertEqual(imported.request.credential, "token")
        XCTAssertFalse(
            imported.request.headers.contains { $0.name.lowercased() == "authorization" })
        XCTAssertEqual(imported.request.body, #"{"value":"a&b"}"#)
        XCTAssertTrue(imported.warnings.contains { $0.contains("redirect") })
    }
    func testCurlEncodedGETAndEmptyRawBodySemantics() throws {
        let imported = try CommandImporter.parse(
            "curl -G https://example.test/search --data-urlencode 'q=a + b' --data 'tag=1&tag=2'")
        let request = try RequestEngine.prepare(imported.request, environment: nil)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.map(\.value), ["a + b", "1", "2"])
        let empty = try CommandImporter.parse("curl https://example.test --data-raw ''")
        XCTAssertEqual(empty.request.method, .POST)
        XCTAssertEqual(try RequestEngine.prepare(empty.request, environment: nil).httpBody, Data())
    }
    func testCurlMultipartAndBinaryReferencesNeverReadPastedPaths() throws {
        let path = "/private/tmp/nonexistent-rill-" + UUID().uuidString
        let file = try CommandImporter.parse(
            "curl https://example.test --data-binary " + CommandWords.quote("@" + path))
        XCTAssertEqual(file.request.binaryFile?.path, path)
        XCTAssertEqual(file.request.binaryFile?.fileID, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let multipart = try CommandImporter.parse(
            "curl https://example.test -F 'first=text' -F "
                + CommandWords.quote(
                    "upload=@" + path + ";type=application/octet-stream;filename=renamed.bin")
                + " --form-string 'literal=@not-a-file'")
        XCTAssertEqual(
            multipart.request.multipartParts?.map(\.name), ["first", "upload", "literal"])
        XCTAssertEqual(multipart.request.multipartParts?[1].filename, "renamed.bin")
        XCTAssertEqual(multipart.request.multipartParts?[2].value, "@not-a-file")
        XCTAssertNil(multipart.request.multipartParts?[2].file)
    }
    func testUnsupportedFlagsAndLossyCombinationsFailExplicitly() {
        for command in [
            "curl -k https://example.test", "curl --config secret https://example.test",
            "curl -o output https://example.test", "curl https://a.test https://b.test",
            "curl https://example.test -H 'X: one' -H 'x: two'",
            "curl https://example.test --data @file", "curl https://example.test -H 'Accept:'",
            "curl https://example.test -X GET --data text", "http --verify=no https://example.test",
            "http https://example.test 'nested[key]=value'",
        ] {
            XCTAssertThrowsError(try CommandImporter.parse(command), command)
        }
    }
    func testHTTPieTypedJSONQueryAuthAndFormFields() throws {
        let imported = try CommandImporter.parse(
            #"http POST https://example.test 'q==a+b' 'name=hello' 'count:=9007199254740993' 'X-Value: exact' --auth-type bearer --auth token"#
        )
        XCTAssertEqual(imported.request.method, .POST)
        XCTAssertEqual(imported.request.auth, .bearer)
        XCTAssertEqual(imported.request.parameters[0].value, "a+b")
        XCTAssertTrue(imported.request.body.contains("9007199254740993"))
        XCTAssertEqual(imported.request.headers[0].value, "exact")
        let form = try CommandImporter.parse(
            "http --form https://example.test name='a b' name=second")
        XCTAssertEqual(form.request.bodyMode, .form)
        XCTAssertEqual(form.request.formFields?.map(\.value), ["a b", "second"])
        let mixed = try CommandImporter.parse(
            "http --form https://example.test before=one 'file@/missing;type=application/octet-stream' after=two"
        )
        XCTAssertEqual(mixed.request.multipartParts?.map(\.name), ["before", "file", "after"])
    }
    func testGeneratedCommandsRoundTripFrozenURLHeadersBodyAndTimeout() throws {
        var draft = RequestDraft()
        draft.url = "https://example.test/search?existing=%2f"
        draft.method = .PATCH
        draft.timeout = 17
        draft.headers = [
            Field(name: "X-Literal", value: "quotes ' and \" and $()"),
            Field(name: "X-Empty", value: ""),
        ]
        draft.parameters = [Field(name: "q", value: "a+b c")]
        draft.body = "literal $HOME\n'quoted'"
        draft.bodyMode = .text
        draft.contentType = "text/plain"
        let original = try RequestEngine.prepare(draft, environment: nil)
        for target in CommandTarget.allCases {
            let generated = try CommandGenerator.generate(
                draft, environment: nil, target: target, includeCredentials: true)
            let imported = try CommandImporter.parse(generated)
            let prepared = try RequestEngine.prepare(imported.request, environment: nil)
            XCTAssertEqual(prepared.url, original.url)
            XCTAssertEqual(prepared.httpMethod, original.httpMethod)
            XCTAssertEqual(prepared.httpBody, original.httpBody)
            XCTAssertEqual(prepared.timeoutInterval, original.timeoutInterval)
            for (key, value) in original.allHTTPHeaderFields ?? [:] {
                XCTAssertEqual(prepared.value(forHTTPHeaderField: key), value, key)
            }
        }
    }
    func testGeneratedAuthIsMaskedByDefaultAndExplicitRevealIsRequired() throws {
        var draft = RequestDraft()
        draft.url = "https://example.test"
        draft.auth = .apiKey
        draft.apiKeyName = "{{header}}"
        draft.credential = "SEEDED_SECRET"
        var environment = Environment(name: "Test")
        environment.variables = [Field(name: "header", value: "Accept")]
        let masked = try CommandGenerator.generate(draft, environment: environment, target: .curl)
        XCTAssertFalse(masked.contains("SEEDED_SECRET"))
        XCTAssertTrue(masked.contains("[REDACTED]"))
        let visible = try CommandGenerator.generate(
            draft, environment: environment, target: .curl, includeCredentials: true)
        XCTAssertTrue(visible.contains("SEEDED_SECRET"))
    }
    func testBinaryCurlGenerationRetainsReferenceAndUnsupportedTargetsFail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0, 255, 1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var draft = RequestDraft()
        draft.url = "https://example.test"
        draft.method = .PUT
        draft.bodyMode = .binary
        draft.binaryFile = try UploadFileReference.capture(url)
        let generated = try CommandGenerator.generate(draft, environment: nil, target: .curl)
        XCTAssertEqual(try CommandImporter.parse(generated).request.binaryFile?.path, url.path)
        XCTAssertThrowsError(
            try CommandGenerator.generate(draft, environment: nil, target: .httpie))
        draft.bodyMode = .multipart
        XCTAssertThrowsError(try CommandGenerator.generate(draft, environment: nil, target: .curl))
    }
    func testCredentialDenialAndFailedMetadataCommitPreserveWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("workspace.json")
        let credentials = TestCredentials()
        let session = WorkspaceSession(url: url, credentials: credentials)
        let baseline = try await session.open()
        try await session.save(baseline)
        let original = try Data(contentsOf: url)
        let incoming = try CommandImporter.parse(
            "curl https://example.test --oauth2-bearer SEEDED_SECRET"
        ).request
        credentials.failures(write: true)
        do {
            _ = try await session.importRequest(incoming, current: baseline)
            XCTFail("Credential denial ignored")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(credentials.nonemptyCount, 0)
        credentials.failures()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        do {
            _ = try await session.importRequest(incoming, current: baseline)
            XCTFail("Read-only directory accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(credentials.nonemptyCount, 0)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let retry = try await session.importRequest(incoming, current: baseline)
        XCTAssertEqual(try credentials.read(retry.requestID), "SEEDED_SECRET")
    }
    func testCommandImportStoresCredentialsOnlyInCompanionStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workspace.json")
        let credentials = TestCredentials()
        let session = WorkspaceSession(url: url, credentials: credentials)
        let baseline = try await session.open()
        try await session.save(baseline)
        let incoming = try CommandImporter.parse(
            "http --auth user:SEEDED_SECRET https://example.test"
        ).request
        let result = try await session.importRequest(incoming, current: baseline)
        XCTAssertEqual(try credentials.read(result.requestID), "SEEDED_SECRET")
        XCTAssertFalse(
            String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("SEEDED_SECRET"))
        XCTAssertEqual(result.workspace.requests.last?.credential, "SEEDED_SECRET")
    }
    func testGeneratedCurlActuallySendsPreparedBodyAndHeadersToLoopback() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        var draft = RequestDraft()
        draft.url = base + "/echo?existing=%2f"
        draft.method = .PATCH
        draft.timeout = 3
        draft.bodyMode = .text
        draft.body = "literal '$HOME'\r\nsecond line"
        draft.contentType = "text/plain"
        draft.headers = [Field(name: "X-Literal", value: "quotes ' and $()")]
        let generated = try CommandGenerator.generate(
            draft, environment: nil, target: .curl, includeCredentials: true)
        let arguments = try CommandWords.parse(generated)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = Array(arguments.dropFirst())
        var environment = ProcessInfo.processInfo.environment
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        environment["no_proxy"] = "127.0.0.1,localhost"
        for key in [
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy",
        ] { environment.removeValue(forKey: key) }
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "PATCH")
        XCTAssertEqual(object["path"] as? String, "/echo?existing=%2f")
        XCTAssertEqual(
            Data(base64Encoded: try XCTUnwrap(object["body"] as? String)), Data(draft.body.utf8))
        let headers = try XCTUnwrap(object["headers"] as? [String: String])
        XCTAssertEqual(
            headers.first { $0.key.lowercased() == "x-literal" }?.value, "quotes ' and $()")
    }
    func testCommonAPIKeyHeadersMoveToAuthAndUnknownAuthWarns() throws {
        let imported = try CommandImporter.parse("curl https://example.test -H 'X-API-Key: secret'")
        XCTAssertEqual(imported.request.auth, .apiKey)
        XCTAssertEqual(imported.request.credential, "secret")
        XCTAssertTrue(imported.request.headers.isEmpty)
        let unknown = try CommandImporter.parse(
            "curl https://example.test -H 'Authorization: Custom value'")
        XCTAssertTrue(unknown.warnings.contains { $0.contains("plain-text") })
    }

}
