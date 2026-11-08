import XCTest

@testable import RillCore

@MainActor final class AdHocRequestTests: XCTestCase {
    private func cli(_ args: [String]) async throws -> ProcessRunResult {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: path), arguments: args)
    }
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
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
