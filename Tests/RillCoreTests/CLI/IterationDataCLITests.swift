import XCTest

@testable import RillCore

@MainActor final class IterationDataCLITests: XCTestCase {
    private func cli(_ arguments: [String]) async throws -> ProcessRunResult {
        guard let path = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("Built CLI required")
        }
        return try await BoundedProcess.run(
            executable: URL(fileURLWithPath: path), arguments: arguments)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func input(
        format: String, url: String, body: String = "{{tag}}/{{optional}}/{{global}}"
    ) throws -> Data {
        if format == "native" {
            var workspace = Workspace()
            var environment = Environment(name: "CI")
            environment.variables = [
                Field(name: "optional", value: "fallback"),
                Field(name: "global", value: "environment"),
            ]
            workspace.environments = [environment]
            workspace.selectedEnvironmentID = environment.id
            for name in ["first", "second"] {
                var request = RequestDraft()
                request.name = name
                request.url = url
                request.method = .POST
                request.bodyMode = .text
                request.body = body
                workspace.requests.append(request)
            }
            return try WorkspaceFile.encode(workspace)
        }
        return try JSONSerialization.data(withJSONObject: [
            "info": [
                "name": "Fixture",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ],
            "variable": [
                ["key": "optional", "value": "fallback"],
                ["key": "global", "value": "environment"],
            ],
            "item": ["first", "second"].map { name in
                [
                    "name": name,
                    "request": [
                        "method": "POST", "url": url, "body": ["mode": "raw", "raw": body],
                    ],
                ]
            },
        ])
    }
    func testJSONAndCSVRowsDriveBothFormatsInOrderWithProtectedInputs() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        for format in ["postman", "native"] {
            for dataFormat in ["json", "csv"] {
                let source = root.appendingPathComponent("\(format)-\(dataFormat) collection.json")
                let rows = root.appendingPathComponent("\(format) data.\(dataFormat)")
                let report = root.appendingPathComponent("\(format)-\(dataFormat) report.json")
                let output = root.appendingPathComponent("\(format)-\(dataFormat) raw.json")
                let collection = try input(format: format, url: base + "/echo")
                let data =
                    dataFormat == "json"
                    ? Data(
                        #"[{"tag":"private-first","optional":"","global":"data"},{"tag":"private-last","global":"data"}]"#
                            .utf8)
                    : Data(
                        "tag,optional,global\nprivate-first,,data\nprivate-last,fallback,data\n"
                            .utf8)
                try collection.write(to: source)
                try data.write(to: rows)
                let result = try await cli([
                    "run", source.path, "--format", format, "--iteration-data", rows.path,
                    "--env-var", "global=override", "--report", report.path, "--output",
                    output.path, "--json",
                ])
                XCTAssertEqual(
                    result.status, 0, String(decoding: result.diagnostics, as: UTF8.self))
                let summary = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: result.output) as? [String: Any])
                XCTAssertEqual(summary["iterationDataRows"] as? Int, 2)
                XCTAssertEqual(summary["attempts"] as? Int, 4)
                let reportData = try Data(contentsOf: report)
                let encoded = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: reportData) as? [String: Any])
                let outcomes = try XCTUnwrap(encoded["outcomes"] as? [[String: Any]])
                XCTAssertEqual(outcomes.compactMap { $0["iteration"] as? Int }, [1, 1, 2, 2])
                let raw = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
                XCTAssertEqual(
                    raw["body"] as? String,
                    Data("private-last/fallback/override".utf8).base64EncodedString())
                XCTAssertFalse(
                    String(decoding: result.output + result.diagnostics + reportData, as: UTF8.self)
                        .contains("private-last"))
                XCTAssertEqual(try Data(contentsOf: source), collection)
                XCTAssertEqual(try Data(contentsOf: rows), data)
            }
        }
    }
    func testMalformedRowsOptionsAndOutputCollisionsBlockWithoutArtifacts() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("collection.json")
        let rows = root.appendingPathComponent("rows.csv")
        let report = root.appendingPathComponent("results.json")
        let collection = try input(format: "postman", url: "http://127.0.0.1:1")
        let valid = Data("tag,optional,global\none,,data\n".utf8)
        try collection.write(to: source)
        try valid.write(to: rows)
        for options in [
            ["--iteration-data", rows.path, "--iterations", "1"],
            ["--iteration-data-format", "csv"],
            ["--iteration-data", rows.path, "--iteration-data-format", "private-unknown"],
            ["--iteration-data", rows.path, "--output", rows.path, "--overwrite"],
            ["--iteration-data", rows.path, "--report", rows.path, "--overwrite"],
            ["--iteration-data", rows.path, "--allure", rows.path],
        ] {
            let result = try await cli(["run", source.path] + options)
            XCTAssertEqual(result.status, 2)
            XCTAssertEqual(try Data(contentsOf: rows), valid)
            XCTAssertEqual(try Data(contentsOf: source), collection)
        }
        for (format, text) in [
            ("csv", "tag,tag\nprivate-value,x"), ("csv", "tag\n\"private-unclosed"), ("json", "[]"),
            ("json", #"[{"tag":"x","tag":"private-duplicate"}]"#),
        ] {
            try Data(text.utf8).write(to: rows)
            let result = try await cli([
                "run", source.path, "--iteration-data", rows.path, "--iteration-data-format",
                format, "--report", report.path, "--json",
            ])
            XCTAssertEqual(result.status, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
            XCTAssertFalse(
                String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                    "private-"))
        }
        let unsupported = try await cli(["preflight", source.path, "--iteration-data", rows.path])
        XCTAssertEqual(unsupported.status, 2)
    }
    func testLateInvalidPostmanRowBlocksAllTrafficAndNativeErrorsRetainPartialRun() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let root = try directory()
        let rows = root.appendingPathComponent("rows.json")
        let data = try JSONSerialization.data(withJSONObject: [
            ["url": base + "/echo"], ["url": "file:///private-iteration-url"],
        ])
        try data.write(to: rows)
        for format in ["postman", "native"] {
            let source = root.appendingPathComponent(format + ".json")
            let report = root.appendingPathComponent(format + "-report.json")
            let collection = try input(format: format, url: "{{url}}", body: "fixture")
            try collection.write(to: source)
            let result = try await cli([
                "run", source.path, "--format", format, "--iteration-data", rows.path, "--report",
                report.path, "--json",
            ])
            XCTAssertEqual(result.status, 2)
            if format == "postman" {
                XCTAssertTrue(result.output.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: report.path))
            } else {
                let reportData = try Data(contentsOf: report)
                let encoded = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: reportData) as? [String: Any])
                let outcomes = try XCTUnwrap(encoded["outcomes"] as? [[String: Any]])
                XCTAssertEqual(outcomes.filter { $0["state"] as? String == "passed" }.count, 2)
                XCTAssertEqual(outcomes.filter { $0["state"] as? String == "failed" }.count, 1)
            }
            XCTAssertFalse(
                String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                    "private-iteration-url"))
            XCTAssertEqual(try Data(contentsOf: source), collection)
        }
        XCTAssertEqual(try Data(contentsOf: rows), data)
    }
}
