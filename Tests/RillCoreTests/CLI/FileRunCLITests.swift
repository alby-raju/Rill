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
    func testDryRunPlansSelectedRowsWithoutReadingTLSCredentialsOrWritingOutputs() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("private-collection.json")
        let environment = root.appendingPathComponent("private-environment.json")
        let rows = root.appendingPathComponent("private-rows.json")
        let report = root.appendingPathComponent("private-report.json")
        let raw = root.appendingPathComponent("private-output.json")
        let marker = Data("existing-report".utf8)
        try marker.write(to: report)
        let leaf: [String: Any] = [
            "name": "private-request",
            "request": [
                "method": "GET", "url": "{{destination}}/private-token",
                "header": [["key": "X-Token", "value": "{{token}}"]],
            ],
        ]
        try collection([
            request("outside selection", "invalid://excluded"),
            ["name": "private-folder", "item": [leaf]],
        ]).write(to: source)
        try JSONSerialization.data(withJSONObject: [
            "_postman_variable_scope": "environment",
            "values": [["key": "token", "value": "private-secret-value", "type": "secret"]],
        ]).write(to: environment)
        try Data(
            #"[{"destination":"http://127.0.0.1:1"},{"destination":"https://private.invalid"}]"#
                .utf8
        )
        .write(to: rows)
        let args = [
            "run", source.path, "--dry-run", "--json", "--folder", "/private-folder",
            "--environment-file", environment.path, "--iteration-data", rows.path,
            "--report", report.path, "--output", raw.path,
        ]
        let result = try await cli(
            args + [
                "--ssl-client-p12", root.appendingPathComponent("missing-private-key.p12").path,
                "--ssl-client-origin", "https://private.invalid",
                "--ssl-passphrase-file",
                root.appendingPathComponent("missing-private-passphrase").path,
            ])
        XCTAssertEqual(result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
        let plan = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.output) as? [String: Any])
        XCTAssertEqual(plan["sendsRequests"] as? Bool, false)
        XCTAssertEqual(plan["baseSteps"] as? Int, 2)
        XCTAssertEqual(plan["environmentSource"] as? String, "explicitFile")
        XCTAssertEqual(plan["tlsInputsDeferred"] as? Bool, true)
        let steps = try XCTUnwrap(plan["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.first?["source"] as? String, "/item/1/item/0")
        XCTAssertEqual(steps.first?["runtimeValidationDeferred"] as? Bool, true)
        XCTAssertFalse(
            String(decoding: result.output + result.diagnostics, as: UTF8.self).contains("private-")
        )
        XCTAssertEqual(try Data(contentsOf: report), marker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        try Data(
            #"[{"destination":"https://private.invalid"},{"destination":"invalid://private-late-row"}]"#
                .utf8
        )
        .write(to: rows)
        let invalid = try await cli(args)
        XCTAssertEqual(invalid.status, 2)
        XCTAssertFalse(
            String(decoding: invalid.diagnostics, as: UTF8.self).contains("private-late-row"))
    }

    func testFileRunReusesPlainHTTPConnectionsWithoutAmbientCookiesOrCrossOriginRedirects()
        async throws
    {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let snapshot = root.appendingPathComponent("snapshot.json")
        try collection(
            ["first", "second", "cross-origin"].map { path in
                [
                    "name": path,
                    "request": ["method": "GET", "url": base + "/run-connection/" + path],
                ]
            }
        ).write(to: source)
        let result = try await cli([
            "run", source.path, "--comparison-output", snapshot.path, "--json",
        ])
        XCTAssertEqual(result.status, 4)
        let report = try RunSnapshotFile.decode(Data(contentsOf: snapshot))
        XCTAssertEqual(report.outcomes.map(\.status), [200, 200, 302])
        let bodies = try report.outcomes.prefix(2).map { outcome in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(outcome.retainedBody))
                    as? [String: Any])
        }
        let ports = try bodies.map { try XCTUnwrap($0["peerPort"] as? Int) }
        XCTAssertEqual(Set(ports).count, 1)
        XCTAssertTrue(bodies.allSatisfy { $0["cookie"] is NSNull })
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

    func testSelectedPostmanMultipartBindsExplicitFilesAndIgnoresExportedPaths() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let manifest = root.appendingPathComponent("attachments.json")
        let config = root.appendingPathComponent("config.json")
        let raw = root.appendingPathComponent("raw.json")
        let first = root.appendingPathComponent("first fixture.bin")
        let second = root.appendingPathComponent("second fixture.bin")
        let firstBytes = Data([0xff, 0, 42])
        let secondBytes = Data([0x80, 0, 43])
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)
        let upload: [String: Any] = [
            "name": "private-upload-request",
            "request": [
                "method": "POST", "url": base + "/echo",
                "body": [
                    "mode": "formdata",
                    "formdata": [
                        [
                            "key": "file", "type": "file", "disabled": true,
                            "src": "/private/disabled",
                        ],
                        ["key": "label", "type": "text", "value": "fixture label"],
                        [
                            "key": "file", "type": "file",
                            "src": [
                                "{{private-exported-path}}", "/private/exported-second",
                            ],
                        ],
                    ],
                ],
            ],
            "event": [
                [
                    "listen": "prerequest",
                    "script": [
                        "exec": [
                            "pm.request.headers.add({key: 'X-Upload-Check', value: 'fixture'});"
                        ]
                    ],
                ]
            ],
        ]
        let input = try collection([
            upload, ["name": "Selected", "item": [upload]],
        ])
        try input.write(to: source)
        let slots = ["/item/1/item/0/attachments/0", "/item/1/item/0/attachments/1"]
        let map = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "attachments": zip(slots, [first, second]).map {
                ["slot": $0, "file": $1.lastPathComponent]
            },
        ])
        try map.write(to: manifest)
        try JSONSerialization.data(withJSONObject: [
            "kind": "rill.run-config", "schemaVersion": 1,
            "options": ["attachments": manifest.lastPathComponent],
        ]).write(to: config)
        let common = ["run", source.path, "--folder", "/Selected", "--translate-scripts", "--json"]
        let missing = try await cli(common + ["--dry-run"])
        XCTAssertEqual(missing.status, 2)
        let missingPlan = try XCTUnwrap(
            JSONSerialization.jsonObject(with: missing.output) as? [String: Any])
        let missingSlots = try XCTUnwrap(missingPlan["attachments"] as? [[String: Any]])
        XCTAssertEqual(missingSlots.compactMap { $0["slot"] as? String }, slots)
        XCTAssertEqual(missingSlots.compactMap { $0["bound"] as? Bool }, [false, false])
        XCTAssertEqual(missingPlan["passed"] as? Bool, false)

        let configured = common + ["--config", config.path]
        let planned = try await cli(configured + ["--dry-run", "--output", raw.path])
        XCTAssertEqual(planned.status, 0, String(decoding: planned.diagnostics, as: UTF8.self))
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        let plan = try XCTUnwrap(
            JSONSerialization.jsonObject(with: planned.output) as? [String: Any])
        let plannedSlots = try XCTUnwrap(plan["attachments"] as? [[String: Any]])
        XCTAssertEqual(plannedSlots.compactMap { $0["bound"] as? Bool }, [true, true])
        let run = try await cli(configured + ["--output", raw.path])
        XCTAssertEqual(run.status, 0, String(decoding: run.diagnostics, as: UTF8.self))
        let echo = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: raw)) as? [String: Any])
        let headers = try XCTUnwrap(echo["headers"] as? [String: String])
        XCTAssertEqual(headers.first { $0.key.lowercased() == "x-upload-check" }?.value, "fixture")
        let body = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(echo["body"] as? String)))
        let firstPart = try XCTUnwrap(body.range(of: firstBytes))
        let secondPart = try XCTUnwrap(body.range(of: secondBytes))
        XCTAssertLessThan(firstPart.upperBound, secondPart.lowerBound)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("exported"))
        XCTAssertFalse(
            String(decoding: planned.output + run.output + run.diagnostics, as: UTF8.self).contains(
                "private-"))
        let alias = root.appendingPathComponent("attachment-hardlink.bin")
        try FileManager.default.linkItem(at: first, to: alias)
        for destination in [first, manifest, alias] {
            let collision = try await cli(
                configured + ["--report", destination.path, "--overwrite"])
            XCTAssertEqual(collision.status, 2)
        }
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
        XCTAssertEqual(try Data(contentsOf: manifest), map)
        XCTAssertEqual(try Data(contentsOf: source), input)
    }

    func testPostmanBinaryAttachmentRequiresExplicitReadableBindingForExecution() async throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"])
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let manifest = root.appendingPathComponent("attachments.json")
        let output = root.appendingPathComponent("response.json")
        let payload = root.appendingPathComponent("private-missing-file")
        try collection([
            [
                "name": "Binary",
                "request": [
                    "method": "PUT", "url": base + "/echo",
                    "body": ["mode": "file", "file": ["src": "/private/exported-body"]],
                ],
            ]
        ]).write(to: source)
        func bind(_ slot: String) throws {
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "attachments": [["slot": slot, "file": payload.lastPathComponent]],
            ]).write(to: manifest)
        }
        let args = [
            "run", source.path, "--attachments", manifest.path, "--output", output.path, "--json",
        ]
        try bind("/item/0/attachments/99")
        let unknown = try await cli(args + ["--dry-run"])
        XCTAssertEqual(unknown.status, 2)
        try bind("/item/0/attachments/0")
        let planned = try await cli(args + ["--dry-run"])
        XCTAssertEqual(planned.status, 0, String(decoding: planned.diagnostics, as: UTF8.self))
        let missing = try await cli(args)
        XCTAssertEqual(missing.status, 2)
        XCTAssertFalse(String(decoding: missing.diagnostics, as: UTF8.self).contains("private-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let bytes = Data([0xff, 0x10, 0])
        try bytes.write(to: payload)
        let sent = try await cli(args)
        XCTAssertEqual(sent.status, 0, String(decoding: sent.diagnostics, as: UTF8.self))
        let echo = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        XCTAssertEqual(echo["body"] as? String, bytes.base64EncodedString())
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
