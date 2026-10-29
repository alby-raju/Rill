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
    }
}
