import XCTest

@testable import RillCore

@MainActor final class InvestigationCLITests: XCTestCase {
    func cli(_ args: [String]) async throws -> ProcessRunResult {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: path), arguments: args)
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rill-investigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func collection(url: String, body: String? = nil) throws -> Data {
        var request: [String: Any] = ["method": body == nil ? "GET" : "POST", "url": url]
        if let body { request["body"] = ["mode": "raw", "raw": body] }
        return try JSONSerialization.data(withJSONObject: [
            "info": [
                "name": "Synthetic",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ], "item": [["name": "PRIVATE-SENTINEL", "request": request]],
        ])
    }
    func testRelativeConfigCLIOverridesSeededSnapshotsAndMetadataComparison() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let source = root.appendingPathComponent("collection with spaces.json")
        let config = root.appendingPathComponent("run config.json")
        let environment = root.appendingPathComponent("env.json")
        try collection(
            url: "{{base}}/echo",
            body: "PRIVATE-SENTINEL/{{token}}/{{$uuid}}/{{$timestamp}}/{{$randomInt -10 10}}"
        ).write(to: source)
        try JSONSerialization.data(withJSONObject: [
            "_postman_variable_scope": "environment", "values": [["key": "base", "value": base]],
        ]).write(to: environment)
        try JSONSerialization.data(withJSONObject: [
            "kind": "rill.run-config", "schemaVersion": 1,
            "options": [
                "environment-file": "env.json", "env-var": ["token=config-value"], "seed": "42",
                "seed-time": "123", "report": "safe.json", "comparison-output": "raw.json",
            ], "flags": ["json": true],
        ]).write(to: config)
        let original = try Data(contentsOf: config)
        let first = try await cli([
            "run", source.path, "--config", config.path, "--env-var", "token=explicit-value",
        ])
        XCTAssertEqual(first.status, 0, String(decoding: first.diagnostics, as: UTF8.self))
        let second = try await cli([
            "run", source.path, "--config", config.path, "--env-var", "token=explicit-value",
            "--report", root.appendingPathComponent("safe2.json").path, "--comparison-output",
            root.appendingPathComponent("raw2.json").path,
        ])
        XCTAssertEqual(second.status, 0, String(decoding: second.diagnostics, as: UTF8.self))
        XCTAssertEqual(try Data(contentsOf: config), original)
        let raw = try RunSnapshotFile.decode(
            Data(contentsOf: root.appendingPathComponent("raw.json")))
        let echoed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(raw.outcomes.first?.retainedBody))
                as? [String: Any])
        let encodedBody = try XCTUnwrap(echoed["body"] as? String)
        let body = String(decoding: try XCTUnwrap(Data(base64Encoded: encodedBody)), as: UTF8.self)
        XCTAssertTrue(body.contains("explicit-value"))
        XCTAssertFalse(body.contains("config-value"))
        XCTAssertTrue(body.contains("/123/"))
        let safeData = try Data(contentsOf: root.appendingPathComponent("safe.json"))
        XCTAssertFalse(
            String(decoding: safeData + first.output + first.diagnostics, as: UTF8.self).contains(
                "PRIVATE-SENTINEL"))
        let paths = [
            root.appendingPathComponent("raw.json").path,
            root.appendingPathComponent("raw2.json").path,
        ]
        let diff = try await cli(
            ["report-diff"] + paths + ["--latency-floor", "86400000", "--json"])
        XCTAssertEqual(diff.status, 0, String(decoding: diff.diagnostics, as: UTF8.self))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: diff.output) as? [String: Any])
        XCTAssertEqual(object["complete"] as? Bool, true)
        XCTAssertEqual(object["changed"] as? Bool, false)
        let ordinary = [
            root.appendingPathComponent("safe.json").path,
            root.appendingPathComponent("safe2.json").path,
        ]
        let incomplete = try await cli(
            ["report-diff"] + ordinary + ["--json", "--latency-floor", "86400000"])
        XCTAssertEqual(incomplete.status, 2)
        let metadata = try await cli(
            ["report-diff"] + ordinary + [
                "--metadata-only", "--json", "--latency-floor", "86400000",
            ])
        XCTAssertEqual(metadata.status, 0)
        let metadataObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadata.output) as? [String: Any])
        XCTAssertEqual(metadataObject["metadataOnly"] as? Bool, true)
        var changed = raw
        changed.outcomes[0].status = 201
        let changedPath = root.appendingPathComponent("changed.json")
        try RunSnapshotFile.encode(changed).write(to: changedPath)
        let drift = try await cli([
            "report-diff", paths[0], changedPath.path, "--json", "--latency-floor", "86400000",
        ])
        XCTAssertEqual(drift.status, 4)
        XCTAssertFalse(
            String(decoding: drift.output + drift.diagnostics, as: UTF8.self).contains(
                "PRIVATE-SENTINEL"))
    }
    func testBadConfigsAndReportFormatsFailBeforeTrafficAndCannotOverwriteConfig() async throws {
        let server = MockServer()
        let root = try directory()
        let base = try await server.start(routes: [MockRoute()])
        do {
            let source = root.appendingPathComponent("collection.json")
            let config = root.appendingPathComponent("config.json")
            try collection(url: base.absoluteString).write(to: source)
            for object: [String: Any] in [
                ["kind": "rill.run-config", "schemaVersion": true],
                [
                    "kind": "rill.run-config", "schemaVersion": 1,
                    "options": ["config": "nested.json"],
                ],
                [
                    "kind": "rill.run-config", "schemaVersion": 1,
                    "options": ["report-format": "unknown", "report": "output.json"],
                ],
                [
                    "kind": "rill.run-config", "schemaVersion": 1,
                    "options": ["report": "config.json"], "flags": ["overwrite": true],
                ],
            ] {
                let data = try JSONSerialization.data(withJSONObject: object)
                try data.write(to: config)
                let result = try await cli(["run", source.path, "--config", config.path])
                XCTAssertEqual(
                    result.status, 2, String(decoding: result.diagnostics, as: UTF8.self))
                XCTAssertEqual(try Data(contentsOf: config), data)
            }
            let count = await server.requestCount()
            XCTAssertEqual(count, 0)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
    func testDeadlineNDJSONAndRecoveredRetriesInAnnotations() async throws {
        var route = MockRoute()
        route.delayMilliseconds = 500
        let server = MockServer()
        let root = try directory()
        let base = try await server.start(routes: [route])
        do {
            let source = root.appendingPathComponent("collection.json")
            let events = root.appendingPathComponent("events.ndjson")
            try collection(url: base.absoluteString).write(to: source)
            let timeout = try await cli([
                "run", source.path, "--deadline", "0.04", "--retries", "5", "--report", events.path,
                "--report-format", "ndjson", "--json", "--github-annotations",
            ])
            XCTAssertEqual(timeout.status, 3)
            XCTAssertTrue(
                String(decoding: timeout.diagnostics, as: UTF8.self).contains("kind=deadline"))
            let summary = try XCTUnwrap(
                JSONSerialization.jsonObject(with: timeout.output) as? [String: Any])
            XCTAssertEqual(summary["timedOut"] as? Bool, true)
            let lines = try Data(contentsOf: events).split(separator: 10)
            let finished = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(XCTUnwrap(lines.last))) as? [String: Any])
            XCTAssertEqual(finished["timedOut"] as? Bool, true)
            await server.stop()
            var first = MockRoute()
            first.status = 500
            first.scenario = MockScenario(name: "retry", nextState: "ok")
            var second = MockRoute()
            second.scenario = MockScenario(name: "retry", requiredState: "ok")
            let restarted = try await server.start(routes: [first, second])
            try collection(url: restarted.absoluteString).write(to: source)
            let recovered = try await cli([
                "run", source.path, "--retries", "1", "--github-annotations", "--json",
            ])
            XCTAssertEqual(recovered.status, 0)
            XCTAssertFalse(
                String(decoding: recovered.diagnostics, as: UTF8.self).contains("::error"))
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }
}
