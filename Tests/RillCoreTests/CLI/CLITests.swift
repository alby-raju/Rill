import XCTest

@testable import RillCore

@MainActor final class CLITests: XCTestCase {
    func cli(_ arguments: [String], timeout: Double = 10) async throws -> ProcessRunResult {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built native CLI required")
        }
        return try await BoundedProcess.run(
            executable: URL(fileURLWithPath: path), arguments: arguments, timeout: timeout,
            outputLimit: 1024 * 1024)
    }
    func testHelpVersionInitAndInputFailuresFromFreshDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("workspace.json").path
        let help = try await cli(["--help"])
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(String(decoding: help.output, as: UTF8.self).contains("run-request"))
        let version = try await cli(["--version"])
        XCTAssertEqual(
            String(decoding: version.output, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines), RillVersion.number)
        let created = try await cli(["init", "--workspace", workspace])
        XCTAssertEqual(created.status, 0)
        let before = try Data(contentsOf: URL(fileURLWithPath: workspace))
        let duplicate = try await cli(["init", "--workspace", workspace])
        XCTAssertEqual(duplicate.status, 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: workspace)), before)
        let invalid = try await cli(["--unknown"])
        XCTAssertEqual(invalid.status, 2)
        let badColor = try await cli(["--color", "rainbow"])
        XCTAssertEqual(badColor.status, 2)
        let conflicting = try await cli(["--json", "--detail"])
        XCTAssertEqual(conflicting.status, 2)
        let quiet = try await cli(["list", "--workspace", workspace, "--quiet"])
        XCTAssertEqual(quiet.status, 0)
        XCTAssertTrue(quiet.output.isEmpty)
    }
    func testSharedRunnerReportsRawOutputAndStableFailureExitCodes() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("HTTP fixture required")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-cli-run-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspace.json")
        let report = directory.appendingPathComponent("report.json")
        let raw = directory.appendingPathComponent("raw.json")
        var workspace = Workspace()
        var request = RequestDraft()
        request.name = "fixture"
        request.url = base + "/json"
        request.expectedStatus = "200"
        request.headers = [Field(name: "X-Secret", value: "seeded-cli-private")]
        workspace.requests = [request]
        try WorkspaceFile.save(workspace, to: file)
        let result = try await cli([
            "run-request", "fixture", "--workspace", file.path, "--report", report.path, "--output",
            raw.path,
        ])
        XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(
            String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                "seeded-cli-private"))
        XCTAssertFalse(
            try String(contentsOf: report, encoding: .utf8).contains("seeded-cli-private"))
        let summary = String(decoding: result.output, as: UTF8.self)
        XCTAssertTrue(summary.contains("RILL / RUN"))
        XCTAssertTrue(summary.contains("REQUEST RESULTS"))
        XCTAssertFalse(summary.contains("\u{1B}"))
        let detailed = try await cli([
            "run-request", "fixture", "--workspace", file.path, "--detail", "--color", "never",
        ])
        XCTAssertEqual(detailed.status, 0)
        XCTAssertTrue(String(decoding: detailed.output, as: UTF8.self).contains("REQUEST DETAILS"))
        let machine = try await cli(["run-request", "fixture", "--workspace", file.path, "--json"])
        let object = try JSONSerialization.jsonObject(with: machine.output) as? [String: Bool]
        XCTAssertEqual(object?["passed"], true)
        let colored = try await cli([
            "run-request", "fixture", "--workspace", file.path, "--color", "always",
        ])
        XCTAssertTrue(String(decoding: colored.output, as: UTF8.self).contains("\u{1B}[32m"))
        let silent = try await cli([
            "run-request", "fixture", "--workspace", file.path, "--detail", "--quiet",
        ])
        XCTAssertEqual(silent.status, 0)
        XCTAssertTrue(silent.output.isEmpty)

        workspace.requests[0].expectedStatus = "201"
        try WorkspaceFile.save(workspace, to: file)
        let assertion = try await cli(["run-request", "fixture", "--workspace", file.path])
        XCTAssertEqual(assertion.status, 4)
        workspace.requests[0].url = "http://127.0.0.1:1/unavailable"
        try WorkspaceFile.save(workspace, to: file)
        let failure = try await cli(["run-request", "fixture", "--workspace", file.path])
        XCTAssertEqual(failure.status, 3)
    }
    func testCLIBackupRestoreGraphQLAndImportPreview() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_LIVE_URL"] else {
            throw XCTSkip("Live fixture required")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-cli-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("workspace.json")
        let backup = directory.appendingPathComponent("snapshot.rillbackup")
        let incoming = directory.appendingPathComponent("incoming.json")
        try WorkspaceFile.save(Workspace(), to: file)
        let saved = try await cli(["backup", "--workspace", file.path, "--output", backup.path])
        XCTAssertEqual(saved.status, 0)
        let restored = try await cli(["restore", backup.path, "--workspace", file.path, "--apply"])
        XCTAssertEqual(restored.status, 0)
        var imported = Workspace()
        var request = RequestDraft()
        request.name = "new"
        imported.requests = [request]
        try WorkspaceFile.save(imported, to: incoming)
        let preview = try await cli(["collection-import", incoming.path, "--workspace", file.path])
        XCTAssertEqual(preview.status, 0)
        XCTAssertTrue(try WorkspaceFile.load(from: file).requests.isEmpty)
        let apply = try await cli([
            "collection-import", incoming.path, "--workspace", file.path, "--apply",
        ])
        XCTAssertEqual(apply.status, 0)
        XCTAssertEqual(try WorkspaceFile.load(from: file).requests.count, 1)
        let graphql = try await cli([
            "graphql", "--endpoint", base + "/graphql", "--query", "query { value }", "--variables",
            "{}", "--workspace", file.path,
        ])
        XCTAssertEqual(graphql.status, 0)
        let rejected = try await cli([
            "graphql", "--endpoint", base + "/graphql-errors", "--query", "query { value }",
            "--workspace", file.path,
        ])
        XCTAssertEqual(rejected.status, 4)
    }
    func testInterruptStopsHeadlessListenerWithCancellationExit() async throws {
        guard let executable = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-cli-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let routes = directory.appendingPathComponent("routes.json")
        let output = directory.appendingPathComponent("out")
        try MockRouteFile.encode([MockRoute()]).write(to: routes)
        try Data().write(to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["mock-serve", "--routes", routes.path]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for _ in 0..<200 {
            if !(try Data(contentsOf: output)).isEmpty || !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let address = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)
        XCTAssertTrue(address.hasPrefix("http://127.0.0.1:"))
        guard process.isRunning else { return XCTFail("Listener exited before interrupt") }
        process.interrupt()
        for _ in 0..<200 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 130) }
        var request = RequestDraft()
        request.url = address
        do {
            _ = try await RequestEngine.execute(request, environment: nil)
            XCTFail("Listener survived cancellation")
        } catch {}
    }

    func testAPIRefreshAndHeadlessLiveCommandsUseSharedServices() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_LIVE_URL"] else {
            throw XCTSkip("Live fixture required")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-cli-api-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = directory.appendingPathComponent("workspace.json")
        let source = directory.appendingPathComponent("api.json")
        try WorkspaceFile.save(Workspace(), to: workspace)
        let definition: [String: Any] = [
            "openapi": "3.1.1", "info": ["title": "Fixture"], "servers": [["url": base]],
            "paths": ["/health": ["get": ["responses": ["200": ["description": "ok"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: definition).write(to: source)
        let preview = try await cli(["openapi-import", source.path, "--workspace", workspace.path])
        XCTAssertEqual(preview.status, 0)
        XCTAssertTrue(try WorkspaceFile.load(from: workspace).requests.isEmpty)
        let applied = try await cli([
            "openapi-import", source.path, "--workspace", workspace.path, "--apply",
        ])
        XCTAssertEqual(applied.status, 0)
        let imported = try WorkspaceFile.load(from: workspace)
        let id = try XCTUnwrap(imported.apiDefinitions?.first?.id)
        let refreshed = try await cli([
            "openapi-refresh", id.uuidString, "--workspace", workspace.path, "--apply",
        ])
        XCTAssertEqual(refreshed.status, 0)
        XCTAssertEqual(
            try WorkspaceFile.load(from: workspace).requests.first?.id, imported.requests.first?.id)
        let sse = try await cli(["sse", "--endpoint", base + "/sse", "--workspace", workspace.path])
        XCTAssertEqual(sse.status, 0)
        XCTAssertFalse(String(decoding: sse.output, as: UTF8.self).contains("first"))
        let socket = try await cli([
            "ws", "--endpoint", base.replacingOccurrences(of: "http://", with: "ws://") + "/echo",
            "--send", "private-stream-payload", "--wait", "0.1", "--workspace", workspace.path,
        ])
        XCTAssertEqual(socket.status, 0)
        XCTAssertFalse(
            String(decoding: socket.output, as: UTF8.self).contains("private-stream-payload"))
    }

}
