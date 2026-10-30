import XCTest

@testable import RillCore

@MainActor final class FileRunCLITests: XCTestCase {
    private func executable() throws -> String {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        return path
    }
    private func cli(_ args: [String]) async throws -> ProcessRunResult {
        try await BoundedProcess.run(
            executable: URL(fileURLWithPath: executable()), arguments: args)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func request(_ name: String, _ url: String) -> [String: Any] {
        ["name": name, "request": ["method": "POST", "url": url]]
    }
    private func collection(_ items: [[String: Any]], variables: [[String: Any]] = []) throws
        -> Data
    {
        try JSONSerialization.data(withJSONObject: [
            "info": [
                "name": "Fixture",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ],
            "item": items, "variable": variables,
        ])
    }
    func testFileRunUsesEnvironmentOverridesAndRedactedReportsWithoutChangingInputs() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let source = root.appendingPathComponent("collection with spaces.json")
        let environment = root.appendingPathComponent("environment with spaces.json")
        let report = root.appendingPathComponent("report.json")
        let output = root.appendingPathComponent("response.json")
        let leaf: [String: Any] = [
            "name": "leaf",
            "request": [
                "method": "POST", "url": "{{base}}/echo",
                "header": [["key": "X-Token", "value": "{{token}}"]],
                "body": ["mode": "raw", "raw": "{{tag}}/{{empty}}"],
            ],
        ]
        let input = try collection(
            [leaf, ["name": "folder", "item": [leaf, leaf]]],
            variables: [
                ["key": "base", "value": "http://invalid.test"],
                ["key": "tag", "value": "collection"], ["key": "empty", "value": "not-empty"],
            ])
        let env = try JSONSerialization.data(withJSONObject: [
            "_postman_variable_scope": "environment",
            "values": [
                ["key": "base", "value": base], ["key": "tag", "value": "environment"],
                ["key": "token", "value": "fixture-private-secret", "type": "secret"],
            ],
        ])
        try input.write(to: source)
        try env.write(to: environment)
        let result = try await cli([
            "run", source.path, "--environment-file", environment.path, "--env-var", "tag=old",
            "--env-var", "tag=override", "--env-var", "empty=", "--iterations", "2", "--report",
            report.path, "--output", output.path, "--json",
        ])
        XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(summary["schemaVersion"] as? Int, 1)
        XCTAssertEqual(summary["passed"] as? Bool, true)
        XCTAssertEqual(summary["attempts"] as? Int, 6)
        let reportData = try Data(contentsOf: report)
        let outcomes = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: reportData) as? [String: Any])?["outcomes"]
                as? [[String: Any]])
        XCTAssertEqual(outcomes.count, 6)
        XCTAssertFalse(
            String(decoding: result.output + result.diagnostics + reportData, as: UTF8.self)
                .contains("fixture-private-secret"))
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(raw["body"] as? String, Data("override/".utf8).base64EncodedString())
        let headers = try XCTUnwrap(raw["headers"] as? [String: String])
        XCTAssertEqual(
            headers.first { $0.key.lowercased() == "x-token" }?.value, "fixture-private-secret")
        XCTAssertEqual(try Data(contentsOf: source), input)
        XCTAssertEqual(try Data(contentsOf: environment), env)
    }
    func testUnsupportedScriptsAndLateInvalidURLBlockBeforeRunArtifacts() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let report = root.appendingPathComponent("report.json")
        var scripted = request("script", "http://127.0.0.1:1")
        scripted["event"] = [["script": ["exec": ["private-script-payload"]]]]
        try collection([scripted]).write(to: source)
        let blocked = try await cli(["run", source.path, "--report", report.path, "--json"])
        XCTAssertEqual(blocked.status, 2)
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: blocked.output) as? [String: Any])
        XCTAssertEqual(summary["passed"] as? Bool, false)
        XCTAssertEqual(summary["sendsRequests"] as? Bool, false)
        XCTAssertFalse(
            String(decoding: blocked.output + blocked.diagnostics, as: UTF8.self).contains(
                "private-script-payload"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
        try collection([request("first", "http://127.0.0.1:1"), request("later", "{{bad}}")]).write(
            to: source)
        let invalid = try await cli([
            "run", source.path, "--env-var", "bad=file:///private/fixture", "--report", report.path,
        ])
        XCTAssertEqual(invalid.status, 2)
        XCTAssertTrue(invalid.output.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
    }
    func testSelectedFolderRunAndPreflightAgreeWithoutTouchingExcludedInputs() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let source = root.appendingPathComponent("folders with spaces.json")
        let report = root.appendingPathComponent("results.json")
        let output = root.appendingPathComponent("raw.json")
        var outside = request("outside-private", "{{missing-outside}}")
        outside["event"] = [["script": ["exec": ["private-script-source"]]]]
        var last = request("last", base + "/echo")
        last["request"] = [
            "method": "POST", "url": base + "/echo",
            "body": ["mode": "raw", "raw": "selected-last"],
        ]
        let input = try collection([
            outside,
            [
                "name": "Parent/One",
                "item": [
                    outside,
                    [
                        "name": "Child~Two",
                        "item": [
                            request("first", base + "/echo"), ["name": "nested", "item": [last]],
                        ],
                    ],
                ],
            ],
        ])
        try input.write(to: source)
        let folder = "/Parent~1One/Child~0Two"
        let preflight = try await cli(["preflight", source.path, "--folder", folder, "--json"])
        XCTAssertEqual(preflight.status, 0, String(decoding: preflight.diagnostics, as: UTF8.self))
        let checked = try XCTUnwrap(
            JSONSerialization.jsonObject(with: preflight.output) as? [String: Any])
        let checks = try XCTUnwrap(checked["checks"] as? [String: Any])
        XCTAssertEqual(checks["requests"] as? Int, 2)
        XCTAssertEqual(checks["folderSelected"] as? Bool, true)
        let run = try await cli([
            "run", source.path, "--folder", folder, "--report", report.path, "--output",
            output.path,
            "--json",
        ])
        XCTAssertEqual(run.status, 0, String(decoding: run.diagnostics, as: UTF8.self))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: run.output) as? [String: Any])
        XCTAssertEqual(summary["attempts"] as? Int, 2)
        XCTAssertEqual(summary["folderSelected"] as? Bool, true)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(raw["body"] as? String, Data("selected-last".utf8).base64EncodedString())
        let ordinary =
            try run.output + run.diagnostics + preflight.output + Data(contentsOf: report)
        XCTAssertFalse(String(decoding: ordinary, as: UTF8.self).contains("outside-private"))
        XCTAssertFalse(String(decoding: ordinary, as: UTF8.self).contains("private-script-source"))
        XCTAssertEqual(try Data(contentsOf: source), input)
        let whole = try await cli(["preflight", source.path, "--json"])
        XCTAssertEqual(whole.status, 2)
    }
    func testFolderErrorsAreRedactedAndNeverProduceRunArtifacts() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let report = root.appendingPathComponent("report.json")
        let input = try collection([
            ["name": "duplicate", "item": []], ["name": "duplicate", "item": []],
            ["name": "empty", "item": []], request("request", "http://127.0.0.1:1"),
        ])
        try input.write(to: source)
        for command in ["run", "preflight"] {
            for folder in [
                "private-relative", "/private-missing", "/duplicate", "/request", "/empty",
                "/bad~2",
            ] {
                var arguments = [command, source.path, "--folder", folder, "--json"]
                if command == "run" { arguments += ["--report", report.path] }
                let result = try await cli(arguments)
                XCTAssertEqual(result.status, 2)
                XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
                XCTAssertFalse(
                    String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                        "private-"))
            }
        }
        let unrelated = try await cli([
            "request", "POST", "http://127.0.0.1:1", "--folder", "/private-missing",
        ])
        XCTAssertEqual(unrelated.status, 2)
        XCTAssertEqual(try Data(contentsOf: source), input)
    }
    func testInvalidFlagsLimitsAndOutputCollisionsPreserveSource() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("input.json")
        let input = try collection([request("fixture", "http://127.0.0.1:1")])
        try input.write(to: source)
        let options: [[String]] = [
            ["--workspace", source.path], ["--ssl-client-cert", source.path],
            ["--env-var", "private-malformed"], ["--iterations", "0"],
            ["--retries", "6"], ["--timeout", "0.1"], ["--overwrite"],
            ["--report", source.path, "--overwrite"], ["--output", source.path, "--overwrite"],
            ["--allure", source.path], ["--report-format", "json"],
        ]
        for option in options {
            let result = try await cli(["run", source.path] + option)
            XCTAssertEqual(result.status, 2, String(decoding: result.diagnostics, as: UTF8.self))
            XCTAssertFalse(
                String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                    "private-malformed"))
            XCTAssertEqual(try Data(contentsOf: source), input)
        }
    }
    func testHTTPChecksAndTransportFailuresHaveDistinctExitCodes() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let source = root.appendingPathComponent("input.json")
        let report = root.appendingPathComponent("report.xml")
        let rawOutput = root.appendingPathComponent("last-response.json")
        try collection([
            request("status", base + "/oauth/token"), request("not-run", base + "/echo"),
        ]).write(to: source)
        let status = try await cli([
            "run", source.path, "--retries", "1", "--report", report.path, "--report-format",
            "junit", "--output", rawOutput.path, "--json",
        ])
        XCTAssertEqual(status.status, 4)
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: status.output) as? [String: Any])
        XCTAssertEqual(summary["passed"] as? Bool, false)
        XCTAssertEqual(summary["attempts"] as? Int, 2)
        XCTAssertEqual(
            (try JSONSerialization.jsonObject(with: Data(contentsOf: rawOutput)) as? [String: Any])?[
                "error"] as? String, "invalid_client")
        XCTAssertTrue(try String(contentsOf: report, encoding: .utf8).contains("<failure"))
        try collection([request("transport", "http://127.0.0.1:1")]).write(to: source)
        let transport = try await cli(["run", source.path, "--json"])
        XCTAssertEqual(transport.status, 3)
        XCTAssertFalse(String(decoding: transport.diagnostics, as: UTF8.self).contains("(unknown)"))
    }
    func testCancellationFlushesAnUnsuccessfulReport() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let source = root.appendingPathComponent("input.json")
        let report = root.appendingPathComponent("cancelled.json")
        let console = root.appendingPathComponent("console.txt")
        // The startup line proves signal handlers are installed and input planning completed.
        var slow = request("slow", base + "/slow")
        slow["request"] = ["method": "GET", "url": base + "/slow"]
        try collection([slow]).write(to: source)
        try Data().write(to: console)
        let handle = try FileHandle(forWritingTo: console)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try executable())
        process.arguments = ["run", source.path, "--report", report.path]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for _ in 0..<200 {
            if !(try Data(contentsOf: console)).isEmpty || !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard process.isRunning, !(try Data(contentsOf: console)).isEmpty else {
            return XCTFail("File runner exited before readiness")
        }
        process.interrupt()
        for _ in 0..<200 {
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 130) }
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(result["cancelled"] as? Bool, true)
        XCTAssertEqual(result["passed"] as? Bool, false)
    }
}
