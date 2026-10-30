import XCTest

@testable import RillCore

private actor IterationVariables {
    var records: [[String: String]] = []
    func append(_ values: [String: String]) -> Int {
        records.append(values)
        return records.count
    }
    func snapshot() -> [[String: String]] { records }
}

@MainActor final class IterationDataTests: XCTestCase {
    private nonisolated static func exchange(_ request: RequestDraft, passed: Bool = true)
        -> Exchange
    {
        Exchange(
            requestID: request.id, requestName: request.name, method: request.method,
            url: request.url, status: 200, duration: 0, headers: [], body: Data(),
            checks: [CheckResult(title: "fixture", passed: passed)])
    }
    func testJSONPreservesEmptyNullExactNumbersAndStructuredValues() throws {
        let input = Data(
            #"[{"empty":"","number":9007199254740993,"flag":true,"nil":null,"object":{"z":1,"a":[false,"x"]}}]"#
                .utf8)
        let data = try IterationData(data: Data([0xef, 0xbb, 0xbf]) + input, format: .json)
        XCTAssertEqual(data.rows[0]["empty"], "")
        XCTAssertEqual(data.rows[0]["number"], "9007199254740993")
        XCTAssertEqual(data.rows[0]["flag"], "true")
        XCTAssertEqual(data.rows[0]["nil"], "null")
        XCTAssertEqual(data.rows[0]["object"], #"{"a":[false,"x"],"z":1}"#)
        let spelling = try IterationData(
            data: Data(#"[{"n":1.2300E+2,"zero":-0}]"#.utf8), format: .json)
        XCTAssertEqual(spelling.rows[0]["n"], "1.2300E+2")
        XCTAssertEqual(spelling.rows[0]["zero"], "-0")
        for malformed in ["[]", "{}", "[null]", #"[{"x":1,"x":2}]"#, #"[{"bad name":"private"}]"#] {
            XCTAssertThrowsError(try IterationData(data: Data(malformed.utf8), format: .json))
        }
    }
    func testCSVQuotesEscapesUnicodeEmptyValuesAndLineEndings() throws {
        let input = "name,body,empty\r\n日本語,\"one,\"\"two\"\"\r\nthree\",\r\nsecond,plain,last"
        let data = try IterationData(
            data: Data([0xef, 0xbb, 0xbf]) + Data(input.utf8), format: .csv)
        XCTAssertEqual(data.rows.count, 2)
        XCTAssertEqual(data.rows[0]["name"], "日本語")
        XCTAssertEqual(data.rows[0]["body"], "one,\"two\"\r\nthree")
        XCTAssertEqual(data.rows[0]["empty"], "")
        XCTAssertEqual(data.rows[1]["empty"], "last")
        XCTAssertEqual(
            try IterationData(data: Data("value\n\n".utf8), format: .csv).rows, [["value": ""]])
        XCTAssertEqual(
            try IterationData(data: Data("\"value\"\n\"\"\n".utf8), format: .csv).rows,
            [["value": ""]])
        for text in [
            "", "name\n", "a,a\n1,2", ",b\n1,2", "a,b\n1", "a\n1,2", "a\n\"unterminated",
            "a\nnot\"quoted", "a\n\"x\"tail", "a\rx", "a\n\"x\" ",
        ] {
            XCTAssertThrowsError(try IterationData(data: Data(text.utf8), format: .csv), text)
        }
        XCTAssertThrowsError(try IterationData(data: Data([0xff]), format: .csv))
    }
    func testDataLimitsAndMergedVariableBudget() throws {
        XCTAssertThrowsError(try IterationData(rows: []))
        XCTAssertThrowsError(try IterationData(rows: Array(repeating: [:], count: 10_001)))
        XCTAssertThrowsError(
            try IterationData(rows: [["x": String(repeating: "x", count: 1024 * 1024 + 1)]]))
        XCTAssertThrowsError(try IterationData(rows: [[String(repeating: "x", count: 129): ""]]))
        XCTAssertThrowsError(
            try IterationData(
                data: Data(repeating: 32, count: IterationData.maximumBytes + 1), format: .json))
        XCTAssertThrowsError(
            try IterationData(
                data: Data(("x\n" + String(repeating: "x", count: 1024 * 1024 + 1)).utf8),
                format: .csv))
        let data = try IterationData(rows: [[:], ["new": "value"]])
        let base = Dictionary(uniqueKeysWithValues: (0..<1024).map { ("k\($0)", "") })
        XCTAssertEqual(try data.variables(at: 0, base: base, overrides: [:]).count, 1024)
        XCTAssertThrowsError(try data.variables(at: 1, base: base, overrides: [:]))
        XCTAssertThrowsError(try data.variables(at: 0, base: [:], overrides: ["": "value"]))
        XCTAssertThrowsError(
            try IterationData(
                rows: Array(repeating: ["x": String(repeating: "x", count: 1024 * 1024)], count: 4))
        )
        let headers = (0..<1024).map { "k\($0)" }.joined(separator: ",")
        let wideCSV =
            headers + "\n"
            + String(repeating: String(repeating: ",", count: 1023) + "\n", count: 100)
        XCTAssertThrowsError(try IterationData(data: Data(wideCSV.utf8), format: .csv))
        var a = RequestDraft()
        var b = RequestDraft()
        a.url = "http://127.0.0.1:1"
        b.url = a.url
        var workspace = Workspace()
        workspace.requests = [a, b]
        let tooMany = try IterationData(rows: Array(repeating: [:], count: 5001))
        XCTAssertThrowsError(
            try NativeFileRun.prepare(
                workspace: WorkspaceFile.encode(workspace), iterationData: tooMany))
        let collection = try JSONSerialization.data(withJSONObject: [
            "info": [
                "name": "Fixture",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ],
            "item": ["one", "two"].map { ["name": $0, "request": ["url": a.url]] },
        ])
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(collection: collection, iterationData: tooMany))
    }
    func testDataRowsResetStateAndRespectInitialOverridePrecedence() async throws {
        let first = RequestDraft()
        let second = RequestDraft()
        let data = try IterationData(rows: [
            ["row": "one", "empty": "", "tag": "data"], ["row": "two", "tag": "data"],
        ])
        var config = RunConfiguration()
        config.iterations = 2
        let captured = IterationVariables()
        let report = try await CollectionRunner.run(
            requests: [first, second],
            environment: WorkflowEngine.environment(["tag": "environment", "empty": "fallback"]),
            configuration: config, iterationData: data, iterationOverrides: ["tag": "override"],
            executor: { request, variables in
                _ = await captured.append(variables)
                var updated = variables
                updated["carry"] = "within-row"
                updated["tag"] = "hook"
                return WorkflowStepResult(
                    exchange: Self.exchange(request), variables: updated, stop: false)
            })
        let values = await captured.snapshot()
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.outcomes.map(\.iteration), [1, 1, 2, 2])
        XCTAssertNil(values[0]["carry"])
        XCTAssertEqual(values[0]["tag"], "override")
        XCTAssertEqual(values[0]["empty"], "")
        XCTAssertEqual(values[1]["carry"], "within-row")
        XCTAssertEqual(values[1]["tag"], "hook")
        XCTAssertNil(values[2]["carry"])
        XCTAssertEqual(values[2]["row"], "two")
        XCTAssertEqual(values[2]["empty"], "fallback")
        XCTAssertEqual(values[2]["tag"], "override")
    }
    func testRetriesStayOnCurrentRowAndFailedChangesAreDiscarded() async throws {
        var config = RunConfiguration()
        config.iterations = 2
        config.retries = 1
        let captured = IterationVariables()
        let data = try IterationData(rows: [["row": "one"], ["row": "two"]])
        let report = try await CollectionRunner.run(
            requests: [RequestDraft()], environment: nil, configuration: config,
            iterationData: data,
            executor: { request, variables in
                let count = await captured.append(variables)
                var updated = variables
                updated["leak"] = "not-across-rows-or-failed-attempts"
                return WorkflowStepResult(
                    exchange: Self.exchange(request, passed: count != 1), variables: updated,
                    stop: false)
            })
        let values = await captured.snapshot()
        XCTAssertTrue(report.passed)
        XCTAssertEqual(values.map { $0["row"] }, ["one", "one", "two"])
        XCTAssertTrue(values.allSatisfy { $0["leak"] == nil })
        XCTAssertEqual(report.outcomes.map(\.iteration), [1, 1, 2])
        XCTAssertEqual(report.outcomes.map(\.attempt), [1, 2, 1])
    }
    func testAllMergedRowsValidateBeforeExecutionAndCountsMustMatch() async throws {
        let captured = IterationVariables()
        var config = RunConfiguration()
        config.iterations = 2
        let data = try IterationData(rows: [[:], ["extra": "value"]])
        let base = WorkflowEngine.environment(
            Dictionary(uniqueKeysWithValues: (0..<1024).map { ("k\($0)", "") }))
        do {
            _ = try await CollectionRunner.run(
                requests: [RequestDraft()], environment: base,
                configuration: config, iterationData: data,
                executor: { request, variables in
                    _ = await captured.append(variables)
                    return WorkflowStepResult(
                        exchange: Self.exchange(request), variables: variables, stop: false)
                })
            XCTFail("Late invalid row was accepted")
        } catch {}
        let values = await captured.snapshot()
        XCTAssertTrue(values.isEmpty)
        do {
            _ = try await CollectionRunner.run(
                requests: [RequestDraft()], environment: nil,
                configuration: RunConfiguration(), iterationData: data)
            XCTFail("Mismatched iteration count was accepted")
        } catch {}
    }
    func testCancellationBetweenRowsReturnsPartialReport() async throws {
        var config = RunConfiguration()
        config.iterations = 2
        let snapshot = config
        let data = try IterationData(rows: [[:], [:]])
        let task = Task {
            try await CollectionRunner.run(
                requests: [RequestDraft()], environment: nil,
                configuration: snapshot, iterationData: data,
                progress: { event in
                    if event.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                },
                executor: { request, variables in
                    WorkflowStepResult(
                        exchange: Self.exchange(request), variables: variables, stop: false)
                })
        }
        let report = try await task.value
        XCTAssertTrue(report.cancelled)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.outcomes.map(\.state), [.passed, .cancelled])
    }
    func testCancelledDataParsingStopsImmediately() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try IterationData(data: Data(), format: .csv)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled data parsing succeeded")
        } catch is CancellationError {}
    }
    func testRunsWithoutDataRetainExistingIterationState() async throws {
        var config = RunConfiguration()
        config.iterations = 2
        let captured = IterationVariables()
        let report = try await CollectionRunner.run(
            requests: [RequestDraft()], environment: nil,
            configuration: config,
            executor: { request, variables in
                _ = await captured.append(variables)
                var updated = variables
                updated["carry"] = "legacy-state"
                return WorkflowStepResult(
                    exchange: Self.exchange(request), variables: updated, stop: false)
            })
        let values = await captured.snapshot()
        XCTAssertTrue(report.passed)
        XCTAssertNil(values[0]["carry"])
        XCTAssertEqual(values[1]["carry"], "legacy-state")
    }
    func testBranchesRetainTheRowAndShareOneExecutionBudget() async throws {
        var config = RunConfiguration()
        config.iterations = 2
        config.executionLimit = 3
        let data = try IterationData(rows: [["row": "one"], ["row": "two"]])
        let captured = IterationVariables()
        let report = try await CollectionRunner.run(
            requests: [RequestDraft()], environment: nil,
            configuration: config, iterationData: data,
            executor: { request, variables in
                _ = await captured.append(variables)
                return WorkflowStepResult(
                    exchange: Self.exchange(request), variables: variables,
                    next: request.id.uuidString, stop: false)
            })
        let values = await captured.snapshot()
        XCTAssertTrue(report.exhausted)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(values.map { $0["row"] }, ["one", "one", "one"])
        XCTAssertEqual(report.outcomes.last?.iteration, 2)
        XCTAssertEqual(report.outcomes.last?.state, .notRun)
    }
}
