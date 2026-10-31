import XCTest

@testable import RillCore

@MainActor final class GlobalsFileTests: XCTestCase {
    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func variables(_ rows: [[String: Any]], scope: String = "globals") throws -> Data {
        try json(["_postman_variable_scope": scope, "values": rows])
    }
    private func collection(_ url: String, rows: [[String: Any]] = [], body: String = "") throws
        -> Data
    {
        try json([
            "info": [
                "name": "Fixture",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ],
            "variable": rows,
            "item": [
                [
                    "name": "Selected",
                    "item": [
                        [
                            "name": "Echo",
                            "request": [
                                "method": "POST", "url": url,
                                "header": [["key": "X-Token", "value": "{{token}}"]],
                                "body": ["mode": "raw", "raw": body],
                            ],
                        ]
                    ],
                ]
            ],
        ])
    }
    private func cli(_ args: [String]) async throws -> ProcessRunResult {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("CLI fixture required")
        }
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: path), arguments: args)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testGlobalsFallbackCollectionEnvironmentAndOverridePrecedence() throws {
        let globals = try variables([
            ["key": "base", "value": "http://127.0.0.1:1"],
            ["key": "token", "value": "private-global-token", "type": "secret"],
            ["key": "c", "value": "globals"], ["key": "e", "value": "globals"],
            ["key": "o", "value": "globals"], ["key": "empty", "value": "globals"],
            ["key": "fallback", "value": "globals"],
            ["key": "disabled", "value": "private-disabled", "disabled": true],
        ])
        let source = try collection(
            "{{base}}/echo",
            rows: [
                ["key": "c", "value": "collection"], ["key": "e", "value": "collection"],
                ["key": "o", "value": "collection"],
                ["key": "fallback", "value": "ignored", "enabled": true, "disabled": true],
            ])
        let environment = try variables(
            [
                ["key": "e", "value": "environment"], ["key": "o", "value": "environment"],
                ["key": "fallback", "value": "ignored", "enabled": false],
                ["key": "empty", "value": ""],
            ], scope: "environment")
        let plan = try PostmanFileRun.prepare(
            collection: source, environment: environment,
            overrides: ["o": "override"], globals: Data([0xef, 0xbb, 0xbf]) + globals)
        let values = WorkflowEngine.variables(in: plan.environment)
        XCTAssertEqual(values["c"], "collection")
        XCTAssertEqual(values["e"], "environment")
        XCTAssertEqual(values["o"], "override")
        XCTAssertEqual(values["empty"], "")
        XCTAssertEqual(values["fallback"], "globals")
        XCTAssertNil(values["disabled"])
        XCTAssertFalse(values.values.contains("private-global-token"))
        let prepared = try RequestEngine.prepare(
            plan.requests[0], environment: plan.environment, secrets: plan.secrets)
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "X-Token"), "private-global-token")
        XCTAssertThrowsError(try plan.secrets.resolve("unrelated-native-secret"))
        let preflight = try CollectionPreflight.inspect(
            collection: source, environment: environment,
            overrides: ["o": "override"], globals: globals)
        XCTAssertTrue(preflight.passed)
        XCTAssertTrue(preflight.globalsSupplied)
    }
    func testInvalidScopesMalformedRowsDuplicatesAndCountLimitsBlock() throws {
        let source = try collection("http://127.0.0.1:1", rows: [["key": "token", "value": ""]])
        for input in [
            Data("{}".utf8), Data("[]".utf8), Data([0xff]),
            try XCTUnwrap(String(decoding: variables([]), as: UTF8.self).data(using: .utf16)),
            try variables([], scope: "environment"),
            try json(["_postman_variable_scope": "globals", "values": "private-invalid"]),
        ] {
            XCTAssertThrowsError(
                try CollectionPreflight.inspect(collection: source, globals: input))
            XCTAssertThrowsError(try PostmanFileRun.prepare(collection: source, globals: input))
        }
        for rows: [[String: Any]] in [
            [
                ["key": "private-duplicate", "value": "a"],
                ["key": "private-duplicate", "value": "b"],
            ],
            [["key": "private-number", "value": 123]], [["key": "", "value": "private-value"]],
            (0...10_000).map { ["key": "k\($0)", "value": ""] },
        ] {
            let input = try variables(rows)
            let check = try CollectionPreflight.inspect(collection: source, globals: input)
            XCTAssertFalse(check.passed)
            XCTAssertTrue(check.issues.allSatisfy { $0.location.hasPrefix("/globals/values") })
            XCTAssertFalse(
                String(decoding: try JSONEncoder().encode(check), as: UTF8.self).contains(
                    "private-"))
            XCTAssertThrowsError(try PostmanFileRun.prepare(collection: source, globals: input))
        }
        XCTAssertTrue(
            try PostmanFileRun.prepare(collection: source, globals: variables([])).requests.count
                == 1)
    }
    func testMergedGlobalsRespectSharedVariableLimitsBeforeExecution() throws {
        let source = try collection("http://127.0.0.1:1", rows: [["key": "token", "value": ""]])
        for rows in [
            [["key": String(repeating: "k", count: 129), "value": ""]],
            [["key": "large", "value": String(repeating: "x", count: 1024 * 1024 + 1)]],
            (0..<1024).map { ["key": "k\($0)", "value": ""] },
            (0..<4).map { ["key": "k\($0)", "value": String(repeating: "x", count: 1024 * 1024)] },
        ] {
            XCTAssertThrowsError(
                try PostmanFileRun.prepare(collection: source, globals: variables(rows)))
        }
    }
    func testCyclesDisabledOnlyValuesAndLaterDataRowsCannotSend() throws {
        let globals = try variables([
            ["key": "token", "value": ""], ["key": "base", "value": "{{other}}"],
            ["key": "other", "value": "{{base}}"],
        ])
        let source = try collection("{{base}}/echo")
        XCTAssertFalse(try CollectionPreflight.inspect(collection: source, globals: globals).passed)
        XCTAssertThrowsError(try PostmanFileRun.prepare(collection: source, globals: globals))
        let disabled = try variables([
            ["key": "base", "value": "http://127.0.0.1:1", "enabled": false],
            ["key": "token", "value": ""],
        ])
        XCTAssertThrowsError(try PostmanFileRun.prepare(collection: source, globals: disabled))
        let rows = try IterationData(rows: [
            ["base": "http://127.0.0.1:1"], ["base": "file:///private-invalid"],
        ])
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(collection: source, iterationData: rows, globals: globals))
        XCTAssertNoThrow(
            try PostmanFileRun.prepare(
                collection: source,
                overrides: ["base": "http://127.0.0.1:1"], iterationData: rows, globals: globals))
    }
    func testCLISelectedRunAndPreflightUseGlobalsSecretsAndDataWithoutChangingInputs() async throws
    {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("HTTP fixture required")
        }
        let root = try directory()
        let source = root.appendingPathComponent("collection with spaces.json")
        let global = root.appendingPathComponent("globals with spaces.json")
        let env = root.appendingPathComponent("environment.json")
        let data = root.appendingPathComponent("data.json")
        let report = root.appendingPathComponent("report.json")
        let output = root.appendingPathComponent("raw.json")
        let inputs = [
            source: try collection(
                "{{base}}/echo", rows: [["key": "c", "value": "collection"]],
                body: "{{g}}/{{c}}/{{e}}/{{d}}/{{o}}/{{empty}}"),
            global: try variables([
                ["key": "base", "value": base],
                ["key": "token", "value": "private-global-token", "type": "secret"],
                ["key": "g", "value": "global"], ["key": "c", "value": "global"],
                ["key": "e", "value": "global"], ["key": "d", "value": "global"],
                ["key": "o", "value": "global"], ["key": "empty", "value": "global"],
            ]),
            env: try variables(
                [["key": "e", "value": "environment"], ["key": "d", "value": "environment"]],
                scope: "environment"),
            data: try json([
                ["d": "data-one", "o": "data", "empty": ""],
                ["d": "data-two", "o": "data", "empty": ""],
            ]),
        ]
        for (path, bytes) in inputs { try bytes.write(to: path) }
        let options = [
            source.path, "--globals", global.path, "--environment-file", env.path,
            "--folder", "/Selected", "--env-var", "o=cli", "--json",
        ]
        let checked = try await cli(["preflight"] + options)
        XCTAssertEqual(checked.status, 0, String(decoding: checked.diagnostics, as: UTF8.self))
        let preflight = try XCTUnwrap(
            JSONSerialization.jsonObject(with: checked.output) as? [String: Any])
        XCTAssertEqual((preflight["checks"] as? [String: Any])?["globalsSupplied"] as? Bool, true)
        let run = try await cli(
            ["run"] + options + [
                "--iteration-data", data.path, "--report", report.path, "--output", output.path,
            ])
        XCTAssertEqual(run.status, 0, String(decoding: run.diagnostics, as: UTF8.self))
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: run.output) as? [String: Any])
        XCTAssertEqual(summary["globalsSupplied"] as? Bool, true)
        XCTAssertEqual(summary["attempts"] as? Int, 2)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(
            raw["body"] as? String,
            Data("global/collection/environment/data-two/cli/".utf8).base64EncodedString())
        let headers = try XCTUnwrap(raw["headers"] as? [String: String])
        XCTAssertEqual(
            headers.first { $0.key.lowercased() == "x-token" }?.value, "private-global-token")
        let ordinary =
            try checked.output + checked.diagnostics + run.output + run.diagnostics
            + Data(contentsOf: report)
        XCTAssertFalse(String(decoding: ordinary, as: UTF8.self).contains("private-global-token"))
        for (path, bytes) in inputs { XCTAssertEqual(try Data(contentsOf: path), bytes) }
    }
    func testCLIInvalidGlobalsAndWrongCommandsBlockBeforeReports() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let global = root.appendingPathComponent("globals.json")
        let report = root.appendingPathComponent("report.json")
        try collection("http://127.0.0.1:1", rows: [["key": "token", "value": ""]]).write(
            to: source)
        for bytes in [
            Data("private-invalid-json".utf8), try variables([], scope: "environment"),
            try variables([["key": "private-key", "value": 123]]),
        ] {
            try bytes.write(to: global)
            for command in ["preflight", "run"] {
                let args =
                    [command, source.path, "--globals", global.path, "--json"]
                    + (command == "run" ? ["--report", report.path] : [])
                let result = try await cli(args)
                XCTAssertEqual(result.status, 2)
                XCTAssertFalse(
                    String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                        "private-"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
            }
        }
        for args in [
            ["run", source.path, "--format", "native"], ["request", "GET", "http://127.0.0.1:1"],
            ["list"],
        ] {
            let result = try await cli(args + ["--globals", global.path])
            XCTAssertEqual(result.status, 2)
        }
    }
    func testCLIOversizedGlobalsAreRejectedBeforeParsing() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let global = root.appendingPathComponent("globals.json")
        try collection("http://127.0.0.1:1").write(to: source)
        try Data().write(to: global)
        let handle = try FileHandle(forWritingTo: global)
        try handle.truncate(atOffset: UInt64(ResourceLimits.workspaceBytes + 1))
        try handle.close()
        for command in ["run", "preflight"] {
            let result = try await cli([command, source.path, "--globals", global.path, "--json"])
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.output.isEmpty)
        }
    }
    func testCLIGlobalsInputAndSymlinkCannotBeOverwrittenByAnyOutput() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let global = root.appendingPathComponent("globals.json")
        let alias = root.appendingPathComponent("alias.json")
        let bytes = try variables([["key": "token", "value": ""]])
        try bytes.write(to: global)
        try collection("http://127.0.0.1:1").write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: global)
        for path in [global, alias] {
            for option in ["--report", "--output", "--allure"] {
                let result = try await cli([
                    "run", source.path, "--globals", global.path, option, path.path, "--overwrite",
                ])
                XCTAssertEqual(result.status, 2)
                XCTAssertTrue(result.output.isEmpty)
                XCTAssertEqual(try Data(contentsOf: global), bytes)
            }
        }
    }
}
