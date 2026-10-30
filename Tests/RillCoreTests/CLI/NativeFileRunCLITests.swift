import XCTest

@testable import RillCore

@MainActor final class NativeFileRunCLITests: XCTestCase {
    private func cli(_ arguments: [String], environment: [String: String] = [:]) async throws
        -> ProcessRunResult
    {
        guard let executable = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        return try await BoundedProcess.run(
            executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: environment)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func request(_ url: String, collection: UUID? = nil) -> RequestDraft {
        var request = RequestDraft(collectionID: collection)
        request.method = .POST
        request.url = url
        return request
    }
    func testNativeFileRunUsesExplicitProcessSecretsAndPreservesInputs() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let collection = RequestCollection(name: "Selected")
        let source = root.appendingPathComponent("native workspace with spaces.json")
        let report = root.appendingPathComponent("report.json")
        let output = root.appendingPathComponent("raw.json")
        var environment = Environment(name: "CI")
        environment.variables = [Field(name: "tag", value: "environment")]
        let secret = NamedSecret(name: "service-token")
        var profile = AuthenticationProfile()
        profile.secretName = secret.name
        var request = request(base + "/echo", collection: collection.id)
        request.authProfileID = profile.id
        request.bodyMode = .text
        request.body = "{{tag}}/{{empty}}"
        request.expectedStatus = "200"
        var workspace = Workspace()
        workspace.collections = [collection]
        workspace.requests = [request]
        workspace.authProfiles = [profile]
        workspace.namedSecrets = [secret]
        workspace.environments = [environment]
        let input = try WorkspaceFile.encode(workspace)
        try input.write(to: source)
        let result = try await cli(
            [
                "run", source.path, "--format", "native", "--collection", "Selected",
                "--environment", "CI",
                "--env-var", "tag=override", "--env-var", "empty=", "--report", report.path,
                "--output", output.path,
                "--json",
            ], environment: ["RILL_SECRET_SERVICE_TOKEN": "fixture-native-private-secret"])
        XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(summary["inputFormat"] as? String, "native")
        XCTAssertEqual(summary["collectionSelected"] as? Bool, true)
        XCTAssertEqual(summary["attempts"] as? Int, 1)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(raw["body"] as? String, Data("override/".utf8).base64EncodedString())
        let headers = try XCTUnwrap(raw["headers"] as? [String: String])
        XCTAssertEqual(
            headers.first { $0.key.lowercased() == "authorization" }?.value,
            "Bearer fixture-native-private-secret")
        let ordinary = try result.output + result.diagnostics + Data(contentsOf: report)
        XCTAssertFalse(
            String(decoding: ordinary, as: UTF8.self).contains("fixture-native-private-secret"))
        XCTAssertEqual(try Data(contentsOf: source), input)
    }
    func testNativeFailureExitCodesAndMissingSecrets() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let source = root.appendingPathComponent("native.json")
        var workspace = Workspace()
        var selected = request(base + "/echo")
        selected.expectedStatus = "201"
        workspace.requests = [selected]
        try WorkspaceFile.encode(workspace).write(to: source)
        let assertion = try await cli(["run", source.path, "--format", "native", "--json"])
        XCTAssertEqual(assertion.status, 4)
        selected.expectedStatus = ""
        selected.url = "http://127.0.0.1:1"
        workspace.requests = [selected]
        try WorkspaceFile.encode(workspace).write(to: source)
        let transport = try await cli(["run", source.path, "--format", "native", "--json"])
        XCTAssertEqual(transport.status, 3)
        selected.url = base + "/echo"
        selected.auth = .bearer
        selected.credential = "{{secret:missing-fixture}}"
        workspace.requests = [selected]
        try WorkspaceFile.encode(workspace).write(to: source)
        let missing = try await cli(["run", source.path, "--format", "native", "--json"])
        XCTAssertEqual(missing.status, 2)
        XCTAssertFalse(
            String(decoding: missing.output + missing.diagnostics, as: UTF8.self).contains(
                "missing-fixture"))
    }
    func testNativeFormatOptionsAndOfflineBlockersNeverWriteArtifacts() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("native.json")
        let report = root.appendingPathComponent("report.json")
        var workspace = Workspace()
        workspace.requests = [request("http://127.0.0.1:1")]
        let input = try WorkspaceFile.encode(workspace)
        try input.write(to: source)
        for options in [
            [], ["--format", "unknown"], ["--format", "native", "--folder", "/private-folder"],
            ["--format", "native", "--environment-file", "private-file"],
            ["--format", "native", "--collection", "private-missing"],
            ["--format", "native", "--report", source.path, "--overwrite"],
        ] {
            let result = try await cli(["run", source.path] + options)
            XCTAssertEqual(result.status, 2)
            XCTAssertEqual(try Data(contentsOf: source), input)
        }
        var hook = RequestHook()
        hook.enabled = true
        hook.source = #"[{"op":"private-invalid"}]"#
        var later = request("http://127.0.0.1:1")
        later.postHook = hook
        workspace.requests.append(later)
        try WorkspaceFile.encode(workspace).write(to: source)
        let blocked = try await cli([
            "run", source.path, "--format", "native", "--report", report.path, "--json",
        ])
        XCTAssertEqual(blocked.status, 2)
        XCTAssertTrue(blocked.output.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        XCTAssertFalse(
            String(decoding: blocked.diagnostics, as: UTF8.self).contains("private-invalid"))
        var tls = TLSProfile()
        tls.mode = .insecure
        workspace.requests = [request("http://127.0.0.1:1")]
        workspace.requests[0].tlsProfileID = tls.id
        workspace.tlsProfiles = [tls]
        try WorkspaceFile.encode(workspace).write(to: source)
        let insecure = try await cli([
            "run", source.path, "--format", "native", "--report", report.path,
        ])
        XCTAssertEqual(insecure.status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        let optedIn = try await cli([
            "run", source.path, "--format", "native", "--allow-insecure", "--report", report.path,
        ])
        XCTAssertEqual(optedIn.status, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
    }
}
