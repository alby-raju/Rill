import XCTest

@testable import RillCore

@MainActor final class AdHocRequestTests: XCTestCase {
    private func cli(_ args: [String], input: Data = Data()) async throws -> ProcessRunResult {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        return try await BoundedProcess.run(
            executable: URL(fileURLWithPath: path), arguments: args, input: input)
    }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testOfflinePreviewUsesRequestPreparationAndRedactsByDefault() async throws {
        let arguments = [
            "request", "POST", "http://127.0.0.1:1/{{route}}", "--offline",
            "--env-var", "route=private-route", "--header", "X-Private: fixture",
            "--data", "private-body",
        ]
        let safe = try await cli(arguments)
        XCTAssertEqual(safe.status, 0)
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: safe.output) as? [String: Any])
        XCTAssertEqual(summary["sendsRequests"] as? Bool, false)
        XCTAssertEqual(summary["bodyBytes"] as? Int, 12)
        XCTAssertFalse(
            String(decoding: safe.output, as: UTF8.self).lowercased().contains("private"))
        let raw = try await cli(arguments + ["--raw-preview"])
        XCTAssertEqual(raw.status, 0)
        let prepared = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw.output) as? [String: Any])
        XCTAssertEqual(prepared["url"] as? String, "http://127.0.0.1:1/private-route")
        XCTAssertEqual(
            prepared["bodyBase64"] as? String, Data("private-body".utf8).base64EncodedString())

        let secret = [
            "request", "GET", "http://127.0.0.1:1/", "--offline",
            "--header", "Authorization: Bearer {{secret:preview-token}}",
        ]
        let deferred = try await cli(secret)
        XCTAssertEqual(deferred.status, 0)
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: deferred.output) as? [String: Any])
        XCTAssertEqual(metadata["deferredCredentials"] as? Bool, true)
        let refused = try await cli(secret + ["--raw-preview"])
        XCTAssertEqual(refused.status, 2)
        XCTAssertTrue(refused.output.isEmpty)
    }

    func testRequestShortcutsInferMethodAndExpandLocalhost() async throws {
        let cases: [([String], String, String)] = [
            ([":"], "GET", "http://localhost/"),
            ([":?ready=1"], "GET", "http://localhost/?ready=1"),
            (
                [":8080/{{path}}", "--env-var", "path=items", "--data", ""],
                "POST", "http://localhost:8080/items"
            ),
            (["patch", ":/items", "--data", "a"], "PATCH", "http://localhost/items"),
            (["https://example.test/", "--stdin"], "POST", "https://example.test/"),
        ]
        for (operands, method, url) in cases {
            let result = try await cli(["request"] + operands + ["--offline", "--raw-preview"])
            XCTAssertEqual(result.status, 0)
            let preview = try XCTUnwrap(
                JSONSerialization.jsonObject(with: result.output) as? [String: Any])
            XCTAssertEqual(preview["method"] as? String, method)
            XCTAssertEqual(preview["url"] as? String, url)
        }
        for operands in [[":0/"], [":65536/"], [":80@localhost/"], ["GET", ":/", "-d", "a"]] {
            let result = try await cli(["request"] + operands + ["--offline"])
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.output.isEmpty)
        }
    }

    func testExplicitDefaultSchemeCompletesBareURLs() async throws {
        let options = ["request", "--offline", "--raw-preview"]
        let cases = [
            (
                "example.test:8080/health?next=https://example.test", "https",
                "https://example.test:8080/health?next=https://example.test"
            ),
            ("http://example.test/health", "https", "http://example.test/health"),
            (":8443/health", "https", "https://localhost:8443/health"),
            ("example.test/health", "http", "http://example.test/health"),
        ]
        for (input, scheme, url) in cases {
            let result = try await cli(options + [input, "--default-scheme", scheme])
            XCTAssertEqual(result.status, 0)
            let preview = try XCTUnwrap(
                JSONSerialization.jsonObject(with: result.output) as? [String: Any])
            XCTAssertEqual(preview["url"] as? String, url)
        }
        for invalid in [
            ["example.test/health"], ["example.test", "--default-scheme", "ftp"],
            ["ftp://example.test", "--default-scheme", "https"],
            ["user:password@example.test", "--default-scheme", "https"],
        ] {
            let result = try await cli(options + invalid)
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.output.isEmpty)
        }
    }

    func testHeaderFilesReachLoopbackAndRemainReadOnly() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("private header=fixture.txt")
        let other = root.appendingPathComponent("empty.txt")
        let original = Data("private-fixture\r\n\n".utf8)
        try original.write(to: file)
        try Data().write(to: other)
        let headers = [
            "--header-file", "X-Private=\(file.path)", "--header-file", "X-Empty=\(other.path)",
        ]
        let offline = try await cli(["request", ":/echo", "--offline"] + headers)
        XCTAssertEqual(offline.status, 0)
        XCTAssertFalse(String(decoding: offline.output, as: UTF8.self).contains("private-fixture"))

        let blocked = try await cli(
            ["request", ":/echo", "--output", file.path, "--overwrite"] + headers)
        XCTAssertEqual(blocked.status, 2)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let sessionConflict = try await cli(
            [
                "request", ":/echo", "--session", file.path, "--session-key-file", other.path,
            ] + headers)
        XCTAssertEqual(sessionConflict.status, 2)
        XCTAssertEqual(try Data(contentsOf: file), original)

        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let sent = try await cli(
            ["request", base + "/echo", "--body-stdout", "-H", "X-Literal:@raw"] + headers)
        XCTAssertEqual(sent.status, 0)
        let echo = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.output) as? [String: Any])
        let received = try XCTUnwrap(echo["headers"] as? [String: String])
        XCTAssertEqual(received["X-Private"], "private-fixture")
        XCTAssertEqual(received["X-Literal"], "@raw")
    }

    func testHeaderFilesRejectInvalidContentWithoutEchoingIt() async throws {
        let file = try directory().appendingPathComponent("private-path.txt")
        let options = ["request", ":/", "--offline", "--header-file", "X-File=\(file.path)"]
        for invalid in [
            Data("private-fixture\r\nInjected: value".utf8),
            Data("{{secret:private-fixture}}".utf8),
            Data([255]), Data(repeating: 65, count: 8193),
        ] {
            try invalid.write(to: file)
            let result = try await cli(options)
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertFalse(String(decoding: result.diagnostics, as: UTF8.self).contains("private-"))
        }
        try Data("value".utf8).write(to: file)
        let duplicate = try await cli(options + ["--header", "x-file:duplicate"])
        XCTAssertEqual(duplicate.status, 2)
    }

    func testQueryFieldsPreserveExistingEncodingOrderAndEmptyValues() async throws {
        let arguments = [
            "request", "GET", "http://127.0.0.1:1/items?existing=%2b#fragment", "--offline",
            "--raw-preview", "--query-param", "tag={{value}}", "--env-var", "value=hello + ☃",
            "--query-param", "tag=", "--query-param", "key=a=b",
        ]
        let result = try await cli(arguments)
        XCTAssertEqual(result.status, 0)
        let prepared = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(
            prepared["url"] as? String,
            "http://127.0.0.1:1/items?existing=%2b&tag=hello%20%2B%20%E2%98%83&tag=&key=a%3Db")
        let invalid = try await cli(arguments + ["--query-param", "=missing-name"])
        XCTAssertEqual(invalid.status, 2)
        XCTAssertTrue(invalid.output.isEmpty)
    }

    func testNestedJSONFieldsPreserveTypesAndRejectConflictingPaths() async throws {
        let args = ["request", "POST", "http://127.0.0.1:1/", "--offline", "--raw-preview"]
        let result = try await cli(
            args + [
                "--json-field", "user[name]=Ada", "--json-field", "user[active]:=true",
                "--json-field", "items[0][id]:=9007199254740993",
                "--json-field", "items[][id]:=null",
                "--json-field", "note={{unset}}",
            ])
        XCTAssertEqual(result.status, 0)
        let preview = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        let base64 = try XCTUnwrap(preview["bodyBase64"] as? String)
        let bytes = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("9007199254740993"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["note"] as? String, "{{unset}}")
        XCTAssertEqual((object["user"] as? [String: Any])?["active"] as? Bool, true)
        XCTAssertEqual((object["items"] as? [[String: Any]])?.count, 2)
        for fields in [
            ["--json-field", "user=x", "--json-field", "user[name]=Ada"],
            ["--json-field", "items[2]=gap"],
            ["--json-field", "value:=bad-json"],
            ["--json-field", "value=x", "--data", "other"],
        ] {
            let invalid = try await cli(args + fields)
            XCTAssertEqual(invalid.status, 2)
            XCTAssertTrue(invalid.output.isEmpty)
        }
    }

    func testStandardInputUsesBufferedBodyPreparation() async throws {
        let url = "http://127.0.0.1:1/"
        let arguments = ["request", "POST", url, "--stdin", "--offline"]
        let body = Data("{\"key\":\"value\"}\n".utf8)
        let result = try await cli(arguments + ["--raw-preview"], input: body)
        XCTAssertEqual(result.status, 0)
        let prepared = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(prepared["bodyBase64"] as? String, body.base64EncodedString())
        let empty = try await cli(arguments)
        XCTAssertEqual(empty.status, 0)
        let invalid = try await cli(arguments, input: Data([0xff]))
        XCTAssertEqual(invalid.status, 2)
        let oversized = try await cli(arguments, input: Data(repeating: 97, count: 1024 * 1024 + 1))
        XCTAssertEqual(oversized.status, 2)
        let conflict = try await cli(arguments + ["--data", "other"])
        XCTAssertEqual(conflict.status, 2)
    }

    func testAdHocPOSTUsesSharedExpansionAndExplicitRawOutput() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let output = try directory().appendingPathComponent("response.json")
        let result = try await cli([
            "request", "POST", base + "/echo", "-H", "X-Fixture:{{value}}", "-d", "{{value}}",
            "--env-var", "value=old", "--env-var", "value=private-fixture", "--output", output.path,
            "--json",
        ])
        XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(summary["schemaVersion"] as? Int, 1)
        XCTAssertEqual(summary["status"] as? Int, 200)
        XCTAssertFalse(
            String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                "private-fixture"))
        let echo = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual((echo["headers"] as? [String: String])?["X-Fixture"], "private-fixture")
        XCTAssertEqual(echo["body"] as? String, Data("private-fixture".utf8).base64EncodedString())
    }

    func testRequestShortcutSendsInferredPostToLoopback() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let port = try XCTUnwrap(URL(string: base)?.port)
        let result = try await cli(["request", ":\(port)/echo", "-d", "shortcut", "--body-stdout"])
        XCTAssertEqual(result.status, 0)
        let echo = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(echo["method"] as? String, "POST")
        XCTAssertEqual(echo["body"] as? String, Data("shortcut".utf8).base64EncodedString())
    }

    func testExplicitWorkspaceEnvironmentOverridesDoNotPersist() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let file = root.appendingPathComponent("workspace.json")
        var workspace = Workspace()
        var environment = Environment(name: "Fixture")
        environment.variables = [
            Field(name: "base", value: "http://invalid.test"), Field(name: "value", value: "old"),
        ]
        workspace.environments = [environment]
        var tls = TLSProfile()
        tls.name = "Fixture TLS"
        tls.mode = .insecure
        workspace.tlsProfiles = [tls]
        try WorkspaceFile.save(workspace, to: file)
        let original = try Data(contentsOf: file)
        let result = try await cli([
            "request", "POST", "{{base}}/echo", "--workspace", file.path, "--environment",
            "Fixture", "--env-var", "base=" + base, "--env-var", "value=", "--data", "{{value}}",
            "--quiet",
        ])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        let refused = try await cli([
            "request", "GET", base, "--workspace", file.path, "--tls", "Fixture TLS",
        ])
        XCTAssertEqual(refused.status, 2)
        XCTAssertTrue(
            String(decoding: refused.diagnostics, as: UTF8.self).contains("--allow-insecure"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testInvalidConfigurationIsRejectedAndExistingOutputIsPreserved() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("body.txt")
        try Data("keep-me".utf8).write(to: file)
        let commands: [[String]] = [
            ["request", "GET", "http://127.0.0.1:1/{{$guid}}"],
            ["request", "GET", "http://127.0.0.1:1", "--allow-insecure"],
            ["request", "GET", "http://127.0.0.1:1", "--timeout", "0.1"],
            ["request", "GET", "http://127.0.0.1:1", "-H", "X-Test:a", "-H", "x-test:b"],
            ["request", "POST", "http://127.0.0.1:1", "--data-file", file.path + ".missing"],

            ["request", "GET", "http://127.0.0.1:1", "--data", "private-payload"],
            ["request", "POST", "http://127.0.0.1:1", "--data", "a", "--data-file", file.path],
            ["request", "GET", "http://127.0.0.1:1", "--report", file.path],
            ["request", "GET", "http://127.0.0.1:1", "--env-var", "private-invalid"],
            ["request", "GET", "http://127.0.0.1:1", "--tls", "missing"],
            ["request", "GET", "http://127.0.0.1:1", "--output", file.path],
            [
                "request", "POST", "http://127.0.0.1:1", "--data-file", file.path, "--output",
                file.path, "--overwrite",
            ],
            ["request", "GET", "http://{{unresolved}}", "--json"],
            ["request", "TRACE", "http://127.0.0.1:1"],
        ]
        for args in commands {
            let result = try await cli(args)
            XCTAssertEqual(result.status, 2, String(decoding: result.diagnostics, as: UTF8.self))
            XCTAssertFalse(String(decoding: result.diagnostics, as: UTF8.self).contains("private-"))
            XCTAssertEqual(try Data(contentsOf: file), Data("keep-me".utf8))
        }
    }
    func testBodyFilesHTTPFailuresAndTransportFailures() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let file = root.appendingPathComponent("body with spaces.txt")
        try Data("fixture-body".utf8).write(to: file)
        let ok = try await cli([
            "request", "POST", base + "/echo", "--data-file", file.path, "--json",
        ])
        XCTAssertEqual(ok.status, 0)
        let failed = try await cli([
            "request", "POST", base + "/oauth/token", "--data", "invalid", "--json",
        ])
        XCTAssertEqual(failed.status, 3)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: failed.output) as? [String: Any])?["status"]
                as? Int, 400)
        let transport = try await cli([
            "request", "GET", "http://127.0.0.1:1", "--timeout", "1", "--json",
        ])
        XCTAssertEqual(transport.status, 3)
        try Data([0xff]).write(to: file)
        let invalid = try await cli(["request", "POST", base + "/echo", "--data-file", file.path])
        XCTAssertEqual(invalid.status, 2)
    }

    func testBinaryAndMultipartUploadsAndFormEncodingPreserveBytes() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        let root = try directory()
        let file = root.appendingPathComponent("private payload.bin")
        let payload = Data([0, 0xff, 10, 13, 0x80])
        try payload.write(to: file)
        func send(_ options: [String]) async throws -> (String, Data) {
            let output = root.appendingPathComponent(UUID().uuidString)
            let result = try await cli(
                ["request", "POST", base + "/echo", "--output", output.path, "--json"] + options)
            XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
            XCTAssertFalse(
                String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                    "private"))
            let echo = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
            let headers = try XCTUnwrap(echo["headers"] as? [String: String])
            let contentType = try XCTUnwrap(
                headers.first { $0.key.lowercased() == "content-type" }?.value)
            let body = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(echo["body"] as? String)))
            return (contentType, body)
        }
        let binary = try await send(["--binary-file", file.path])
        XCTAssertEqual(binary.0, "application/octet-stream")
        XCTAssertEqual(binary.1, payload)
        let form = try await send(["--form", "item=private one", "--form", "item=+"])
        XCTAssertEqual(form.0, "application/x-www-form-urlencoded")
        XCTAssertEqual(String(decoding: form.1, as: UTF8.self), "item=private+one&item=%2B")
        let multipart = try await send([
            "--form", "item=first", "--form", "attachment@" + file.path, "--form", "item=last",
        ])
        XCTAssertTrue(multipart.0.hasPrefix("multipart/form-data; boundary="))
        let first = try XCTUnwrap(multipart.1.range(of: Data("first".utf8)))
        let binaryPart = try XCTUnwrap(multipart.1.range(of: payload))
        let last = try XCTUnwrap(multipart.1.range(of: Data("last".utf8)))
        XCTAssertLessThan(first.upperBound, binaryPart.lowerBound)
        XCTAssertLessThan(binaryPart.upperBound, last.lowerBound)
        let collision = try await cli([
            "request", "POST", base + "/echo", "--form", "attachment@" + file.path,
            "--output", file.path, "--overwrite",
        ])
        XCTAssertEqual(collision.status, 2)
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }

    func testAdHocUsesExplicitMutualTLSWithoutWorkspace() async throws {
        let variables = ProcessInfo.processInfo.environment
        let origin = try XCTUnwrap(variables["RILL_TEST_MTLS_URL"])
        let tls = URL(fileURLWithPath: try XCTUnwrap(variables["RILL_TEST_TLS_DIR"]))
        let phrase = try directory().appendingPathComponent("private passphrase.txt")
        try Data("rill-fixture\n".utf8).write(to: phrase)
        let args = [
            "request", "GET", origin + "/client-rsa", "--ca-cert",
            tls.appendingPathComponent("ca.pem").path, "--ssl-client-p12",
            tls.appendingPathComponent("client.p12").path, "--ssl-passphrase-file", phrase.path,
            "--json",
        ]
        let result = try await cli(args + ["--ssl-client-origin", origin])
        XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
        let wrong = try await cli(args + ["--ssl-client-origin", "https://localhost:1"])
        XCTAssertEqual(wrong.status, 3)
        let collision = try await cli(
            args + [
                "--ssl-client-origin", origin, "--output", phrase.path, "--overwrite",
            ])
        XCTAssertEqual(collision.status, 2)
        XCTAssertEqual(try Data(contentsOf: phrase), Data("rill-fixture\n".utf8))
    }

    func testBodyStdoutPreservesResponseBytesAndHTTPFailureStatus() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let success = try await cli(["request", "GET", base + "/bytes/5", "--body-stdout"])
        XCTAssertEqual(success.status, 0)
        XCTAssertEqual(success.output, Data("xxxxx".utf8))
        XCTAssertTrue(success.diagnostics.isEmpty)

        let failure = try await cli([
            "request", "POST", base + "/oauth/token", "--data", "invalid", "--body-stdout",
        ])
        XCTAssertEqual(failure.status, 3)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: failure.output) as? [String: String])
        XCTAssertEqual(body["error"], "invalid_client")
        XCTAssertFalse(failure.diagnostics.isEmpty)

        let incompatible = try await cli([
            "request", "GET", base + "/bytes/5", "--body-stdout", "--json",
        ])
        XCTAssertEqual(incompatible.status, 2)
        XCTAssertTrue(incompatible.output.isEmpty)
    }

    func testResponseHeaderOutputSelectsFinalHeadersWithoutReadingBody() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        let all = try await cli(["request", base + "/echo", "--headers-stdout"])
        XCTAssertEqual(all.status, 0)
        let text = String(decoding: all.output, as: UTF8.self).lowercased()
        XCTAssertTrue(text.hasPrefix("http 200\n"))
        XCTAssertTrue(text.contains("\ncontent-type: application/json\n"))
        XCTAssertFalse(text.contains("\"method\""))

        let selected = try await cli([
            "request", base + "/cookie/redirect", "--no-follow", "--json",
            "--response-header", "LOCATION", "--response-header", "location",
            "--response-header", "X-Absent",
        ])
        XCTAssertEqual(selected.status, 3)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: selected.output) as? [String: Any])
        let headers = try XCTUnwrap(object["headers"] as? [[String: String]])
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["status"] as? Int, 302)
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers.first?["name"]?.lowercased(), "location")
        XCTAssertEqual(headers.first?["value"], "/echo")

        let large = try await cli(["request", base + "/large", "--headers-stdout"])
        XCTAssertEqual(large.status, 0)
        XCTAssertTrue(String(decoding: large.output, as: UTF8.self).hasPrefix("HTTP 200\n"))

        for options in [["--offline"], ["--body-stdout"], ["--response-header", "bad:name"]] {
            let rejected = try await cli(["request", base + "/echo", "--headers-stdout"] + options)
            XCTAssertEqual(rejected.status, 2)
            XCTAssertTrue(rejected.output.isEmpty)
        }
    }

    func testNoFollowReturnsRedirectAndPreservesDownloadDestination() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let args = ["request", "GET", base + "/cookie/redirect", "--json"]
        let followed = try await cli(args)
        XCTAssertEqual(followed.status, 0)
        let file = try directory().appendingPathComponent("download")
        let previous = Data("previous download".utf8)
        try previous.write(to: file)
        for options in [[], ["--download", file.path, "--overwrite"]] {
            let stopped = try await cli(args + ["--no-follow"] + options)
            XCTAssertEqual(stopped.status, 3)
            let summary = try XCTUnwrap(
                JSONSerialization.jsonObject(with: stopped.output) as? [String: Any])
            XCTAssertEqual(summary["status"] as? Int, 302)
        }
        XCTAssertEqual(try Data(contentsOf: file), previous)
    }

    func testDownloadStreamsBeyondPreviewLimitAndKeepsOldFileOnFailure() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        let root = try directory()
        let output = root.appendingPathComponent("download.bin")
        let marker = Data("keep existing file".utf8)
        try marker.write(to: output)
        let common = ["--download", output.path, "--json"]
        let exists = try await cli(["request", "GET", base + "/large"] + common)
        XCTAssertEqual(exists.status, 2)
        for endpoint in ["download-truncated", "download-over-limit", "download-denied"] {
            let failed = try await cli(
                ["request", "GET", base + "/" + endpoint] + common + ["--overwrite"])
            XCTAssertEqual(failed.status, 3, endpoint)
            XCTAssertEqual(try Data(contentsOf: output), marker, endpoint)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: root.path), ["download.bin"])
        }
        let success = try await cli(["request", "GET", base + "/large"] + common + ["--overwrite"])
        XCTAssertEqual(success.status, 0, String(decoding: success.diagnostics, as: UTF8.self))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: success.output) as? [String: Any])
        let body = try Data(contentsOf: output)
        XCTAssertEqual(summary["bodyBytes"] as? Int, 17 * 1024 * 1024)
        XCTAssertEqual(body, Data(repeating: 120, count: 17 * 1024 * 1024))
        let fresh = root.appendingPathComponent("fresh.bin")
        let created = try await cli([
            "request", "GET", base + "/chunked/3", "--download", fresh.path,
        ])
        XCTAssertEqual(created.status, 0)
        XCTAssertEqual(try Data(contentsOf: fresh), Data("xxx".utf8))
    }

    func testRecognizableForeignPreflightFormatsHaveRedactedGuidance() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("input.json")
        for (text, expected) in [
            ("{\"resources\":[],\"private-marker\":true}", "Insomnia"),
            ("{\"requests\":[],\"collections\":[],\"private-marker\":true}", "native Rill"),
        ] {
            try Data(text.utf8).write(to: file)
            let result = try await cli(["preflight", file.path])
            XCTAssertEqual(result.status, 2)
            let diagnostic = String(decoding: result.diagnostics, as: UTF8.self)
            XCTAssertTrue(diagnostic.contains(expected), diagnostic)
            XCTAssertFalse(diagnostic.contains("private-marker"))
        }
        // Extra vendor metadata must not misclassify an otherwise valid Postman collection.
        let postman =
            #"{"info":{"name":"fixture","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},"item":[{"name":"fixture","request":{"method":"GET","url":"http://127.0.0.1:1"}}],"resources":[],"requests":[],"collections":[]}"#
        try Data(postman.utf8).write(to: file)
        let valid = try await cli(["preflight", file.path])
        XCTAssertEqual(valid.status, 0, String(decoding: valid.diagnostics, as: UTF8.self))

    }
}
