import XCTest
import Foundation
@testable import RillCore

actor AttemptCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}
actor ConcurrencyProbe {
    var active = 0
    var peak = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
    func maximum() -> Int { peak }
}
@MainActor final class RunnerTests: XCTestCase {
    nonisolated static func exchange(_ request: RequestDraft, body: String = #"{"token":"next","items":[1,{"x":"y"}]}"#, status: Int = 200, passed: Bool = true) -> Exchange {
        Exchange(requestID: request.id, requestName: request.name, method: request.method, url: request.url, status: status, duration: 0.01,
                 headers: [Field(name: "X-Token", value: "header-value")], body: Data(body.utf8), checks: [CheckResult(title: "seeded-secret", passed: passed)])
    }
    func testAssertionsExactJSONPointersAndMissingValues() throws {
        let request = RequestDraft(), response = Self.exchange(RequestDraft())
        var rules: [ResponseAssertion] = []
        func add(_ kind: AssertionKind, _ selector: String, _ expected: String) { var rule = ResponseAssertion(); rule.kind = kind; rule.selector = selector; rule.expected = expected; rules.append(rule) }
        add(.status, "", "200"); add(.headerExists, "x-token", ""); add(.headerContains, "X-Token", "value")
        add(.bodyContains, "", "next"); add(.jsonEquals, "$.items[1].x", #""y""#); add(.jsonEquals, "/items/0", "1.0")
        XCTAssertTrue(ResponseRules.evaluate(rules, response: response).allSatisfy(\.passed))
        for bad in ["$.missing", "$..token", "$.items[*]", "/invalid~2", "$.items[01]"] {
            var rule = ResponseAssertion(); rule.kind = .jsonEquals; rule.selector = bad; rule.expected = "null"
            XCTAssertFalse(ResponseRules.evaluate([rule], response: response)[0].passed)
        }
        var invalid = ResponseAssertion(); invalid.kind = .status; invalid.expected = "nonsense"
        XCTAssertFalse(ResponseRules.evaluate([invalid], response: response)[0].passed)
        XCTAssertThrowsError(try ResponseJSON.value(Data(#"{"a":1,"a":2}"#.utf8), path: "/a"))
        XCTAssertNotNil(request.id)
    }
    func testExtractionIsTransactionalAndPreservesJSONValues() throws {
        let response = Self.exchange(RequestDraft())
        var json = ResponseExtraction(); json.selector = "$.items"; json.variable = "items"
        var header = ResponseExtraction(); header.kind = .header; header.selector = "x-token"; header.variable = "header"
        let updates = try ResponseRules.extract([json, header], response: response)
        XCTAssertEqual(updates["header"], "header-value")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(updates["items"]!.utf8)))
        header.selector = "missing"
        XCTAssertThrowsError(try ResponseRules.extract([json, header], response: response))
        json.selector = "/token"; json.variable = ""
        XCTAssertThrowsError(try ResponseRules.extract([json], response: response))
    }
    func testHookMutationCryptoConditionBranchAndOpaqueLogs() throws {
        var hook = RequestHook(); hook.enabled = true; hook.source = #"[{"op":"set","name":"x","value":"abc"},{"op":"sha256","name":"hash","value":"{{x}}"},{"op":"hmac","name":"signature","key":"key","value":"The quick brown fox jumps over the lazy dog"},{"op":"uuid","name":"nonce"},{"op":"time","name":"clock"},{"op":"if","value":"{{x}}","equals":"abc","then":[{"op":"url","value":"https://example.test/{{x}}"},{"op":"header","name":"X-Hash","value":"{{hash}}"}]},{"op":"assert","value":"{{x}}","equals":"abc"},{"op":"log","value":"private-log"},{"op":"next","value":"second"}]"#
        let original = RequestDraft()
        let result = try HookRuntime.execute(hook, request: original, variables: [:])
        XCTAssertEqual(result.request.url, "https://example.test/abc")
        XCTAssertEqual(result.variables["hash"], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(result.variables["signature"], "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        XCTAssertNotNil(UUID(uuidString: result.variables["nonce"]!)); XCTAssertNotNil(Int64(result.variables["clock"]!))
        XCTAssertEqual(result.next, "second"); XCTAssertEqual(result.logs, ["private-log"])
        XCTAssertEqual(original.url, "")
    }
    func testHookRejectsExecutionAndResourceEscapesIncludingUnreachableBranches() throws {
        for source in ["while(true) {}", #"[{"op":"eval","value":"1"}]"#, #"[{"op":"set","name":"response.status","value":"200"}]"#, #"[{"op":"if","value":"a","equals":"b","then":[{"op":"network","value":"https://example.test"}]}]"#, #"[{"op":"url","value":3}]"#, #"[{"op":"set","name":"ok","value":"{{secret:token}}"}]"#] {
            var hook = RequestHook(); hook.enabled = true; hook.source = source
            XCTAssertThrowsError(try HookRuntime.execute(hook, request: RequestDraft(), variables: [:]), source)
        }
        var hook = RequestHook(); hook.enabled = true
        hook.source = "[" + Array(repeating: #"{"op":"uuid","name":"n"}"#, count: 1025).joined(separator: ",") + "]"
        XCTAssertThrowsError(try HookRuntime.validate(hook))
        hook.source = #"[{"op":"log","value":"{{large}}"}]"#
        XCTAssertThrowsError(try HookRuntime.execute(hook, request: RequestDraft(), variables: ["large": String(repeating: "x", count: 17_000)]))
    }
    func testDynamicTemplatesAreIndependentInsideNestedVariables() throws {
        let text = try VariableExpansion.resolve("{{nested}} {{nested}}", values: ["nested": "{{$uuid}}"])
        let parts = text.split(separator: " ")
        XCTAssertEqual(parts.count, 2); XCTAssertNotEqual(parts[0], parts[1])
        XCTAssertTrue(try DynamicTemplates.generate("$email").hasSuffix("@example.test"))
        XCTAssertEqual(try DynamicTemplates.generate("$randomInt 7 7"), "7")
        for bad in ["$unknown", "$randomInt 3 1", "$randomInt x 2", "$uuid extra"] { XCTAssertThrowsError(try DynamicTemplates.generate(bad)) }
    }
    func testOrderedRetryRetentionAndReports() async throws {
        var first = RequestDraft(); first.name = "secret-name"; first.url = "https://example.test?token=secret-url"
        var second = RequestDraft(); second.name = "second"
        let firstID = first.id, counter = AttemptCounter()
        var settings = RunConfiguration(); settings.retries = 1; settings.retentionBytes = 1
        let report = try await CollectionRunner.run(requests: [first, second], environment: nil, configuration: settings, executor: { request, variables in
            let count = await counter.next()
            return WorkflowStepResult(exchange: Self.exchange(request, passed: count != 1), variables: variables, stop: false)
        })
        XCTAssertEqual(report.outcomes.map(\.requestID), [firstID, firstID, second.id])
        XCTAssertEqual(report.outcomes.map(\.attempt), [1, 2, 1]); XCTAssertTrue(report.passed)
        XCTAssertTrue(report.outcomes.allSatisfy { $0.retainedBody == nil && $0.bodyOmitted && $0.fingerprint != nil })
        for format in RunReportFormat.allCases {
            let files = try RunReportExporter.files(report, format: format)
            XCTAssertFalse(files.isEmpty)
            for data in files.values {
                let text = String(decoding: data, as: UTF8.self)
                for secret in ["secret-name", "secret-url", "seeded-secret", "header-value", "next"] { XCTAssertFalse(text.contains(secret), format.rawValue + ": " + secret) }
                if format == .json || format == .allure { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data)) }
                if format == .junit { XCTAssertTrue(text.contains("tests=\"3\"")) }
            }
        }
    }
    func testBranchingBudgetAndInvalidTargetRollback() async throws {
        var first = RequestDraft(); first.name = "first"
        var second = RequestDraft(); second.name = "second"
        let firstID = first.id
        var config = RunConfiguration(); config.executionLimit = 3
        let looping = try await CollectionRunner.run(requests: [first, second], environment: nil, configuration: config, executor: { request, variables in
            WorkflowStepResult(exchange: Self.exchange(request), variables: variables, next: firstID.uuidString, stop: false)
        })
        XCTAssertTrue(looping.exhausted); XCTAssertFalse(looping.passed)
        XCTAssertEqual(looping.outcomes.filter { $0.state == .passed }.count, 3)
        XCTAssertTrue(looping.outcomes.contains { $0.requestID == second.id && $0.state == .notRun })
        let invalid = try await CollectionRunner.run(requests: [first], environment: nil, configuration: RunConfiguration(), executor: { request, variables in
            WorkflowStepResult(exchange: Self.exchange(request), variables: ["leak": "private"], next: "unknown", stop: false)
        })
        XCTAssertFalse(invalid.passed); XCTAssertEqual(invalid.outcomes.first?.failure, "invalidBranch")
    }
    func testCancellationInterruptsPacingAndEmptyRunsCannotPass() async throws {
        let empty = try await CollectionRunner.run(requests: [], environment: nil, configuration: RunConfiguration())
        XCTAssertFalse(empty.passed)
        var config = RunConfiguration(); config.delayMilliseconds = 60_000
        let first = RequestDraft(), second = RequestDraft(), snapshot = config
        let task = Task {
            try await CollectionRunner.run(requests: [first, second], environment: nil, configuration: snapshot, progress: { _ in }, executor: { request, variables in
                WorkflowStepResult(exchange: Self.exchange(request), variables: variables, stop: false)
            })
        }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        let report = try await task.value
        XCTAssertTrue(report.cancelled); XCTAssertFalse(report.passed)
        XCTAssertTrue(report.outcomes.contains { $0.state == .cancelled })
    }
    func testLoadPercentilesConcurrencyAndBudgetValidation() async throws {
        let report = LoadReport(samples: (1...100).map { LatencySample(index: $0, state: .passed, duration: Double($0), status: 200) }, duration: 10)
        XCTAssertEqual(report.percentile(0.5), 50); XCTAssertEqual(report.percentile(0.95), 95); XCTAssertEqual(report.percentile(0.99), 99)
        XCTAssertEqual(report.minimum, 1); XCTAssertEqual(report.maximum, 100); XCTAssertEqual(report.throughput, 10)
        XCTAssertNil(report.percentile(.nan))
        var settings = LoadConfiguration(); settings.count = 8; settings.concurrency = 3
        let run = try await LoadRunner.run(request: RequestDraft(), environment: nil, configuration: settings, executor: { request, variables in
            WorkflowStepResult(exchange: Self.exchange(request), variables: variables, stop: false)
        })
        XCTAssertTrue(run.passed); XCTAssertEqual(run.samples.count, 8)
        settings.concurrency = 65; XCTAssertThrowsError(try settings.validate())
        var config = RunConfiguration(); config.iterations = 10_001; XCTAssertThrowsError(try config.validate())
    }
    func testNativeImportDisablesExecutableHooksAndPersistencePreservesSources() throws {
        var workspace = Workspace.starter, hook = RequestHook(); hook.enabled = true; hook.source = #"[{"op":"uuid","name":"nonce"}]"#
        workspace.requests[0].preHook = hook
        let decoded = try WorkspaceFile.decode(WorkspaceFile.encode(workspace))
        XCTAssertEqual(decoded.requests[0].preHook, hook)
        let imported = try WorkspaceImport.merging(workspace, into: Workspace())
        XCTAssertEqual(imported.requests[0].preHook?.enabled, false)
        XCTAssertEqual(imported.requests[0].preHook?.source, hook.source)
    }
    func testSharedWorkflowAgainstLoopbackExtractsThenRunsPostHook() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else { throw XCTSkip("Loopback fixture required") }
        var request = RequestDraft(); request.url = base + "/json"; request.expectedStatus = "200"
        var extraction = ResponseExtraction(); extraction.selector = "$"; extraction.variable = "captured"
        request.extractions = [extraction]
        var hook = RequestHook(); hook.enabled = true; hook.source = #"[{"op":"set","name":"status","value":"{{response.status}}"},{"op":"assert","value":"{{status}}","equals":"200"}]"#
        request.postHook = hook
        let result = try await WorkflowEngine.execute(request, variables: [:])
        XCTAssertTrue(result.passed); XCTAssertEqual(result.variables["status"], "200"); XCTAssertNotNil(result.variables["captured"])
        request.postHook?.source = #"[{"op":"set","name":"leak","value":"private"},{"op":"assert","value":"a","equals":"b"}]"#
        let failed = try await WorkflowEngine.execute(request, variables: ["original": "yes"])
        XCTAssertFalse(failed.passed); XCTAssertEqual(failed.variables, ["original": "yes"])
    }
    func testMatrixIsolationAndLoadUseSharedLoopbackExecution() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else { throw XCTSkip("Loopback fixture required") }
        var request = RequestDraft(); request.url = base + "/echo?value={{value}}"; request.expectedStatus = "200"
        var a = Environment(name: "a"); a.variables = [Field(name: "value", value: "first")]
        var b = Environment(name: "b"); b.variables = [Field(name: "value", value: "second")]
        let matrix = try await MatrixRunner.run(requests: [request], environments: [a, b], concurrency: 2, configuration: RunConfiguration())
        XCTAssertTrue(matrix.passed); XCTAssertEqual(matrix.runs.map(\.environmentID), [a.id, b.id])
        XCTAssertTrue(matrix.comparisons[0].bodiesDiffer); XCTAssertFalse(matrix.comparisons[0].statesDiffer)
        XCTAssertEqual(a.variables[0].value, "first")
        var config = LoadConfiguration(); config.count = 4; config.concurrency = 2
        let load = try await LoadRunner.run(request: request, environment: a, configuration: config)
        XCTAssertTrue(load.passed); XCTAssertEqual(load.successes, 4)
    }
    func testFailedEarlierVisitCannotBeErasedByLaterBranchSuccess() async throws {
        var a = RequestDraft(); a.name = "a"
        var b = RequestDraft(); b.name = "b"
        let counter = AttemptCounter(), firstID = a.id
        var config = RunConfiguration(); config.stopOnFailure = false
        let report = try await CollectionRunner.run(requests: [a, b], environment: nil, configuration: config, executor: { request, variables in
            let count = await counter.next()
            return WorkflowStepResult(exchange: Self.exchange(request, passed: count != 1), variables: variables, next: count == 2 ? firstID.uuidString : nil, stop: count == 3)
        })
        XCTAssertFalse(report.passed); XCTAssertEqual(report.outcomes.count, 3)
    }
    func testPreHookIsAppliedOnceForEverySnippetAndDisabledDraftsPersist() throws {
        var request = RequestDraft(); request.url = "https://example.test"
        var hook = RequestHook(); hook.enabled = true; hook.source = #"[{"op":"uuid","name":"nonce"},{"op":"header","name":"X-Nonce","value":"{{nonce}}"}]"#
        request.preHook = hook
        let frozen = try FrozenClientRequest.capture(request, environment: nil)
        let nonce = try XCTUnwrap(frozen.headers.first { $0.key.lowercased() == "x-nonce" }?.value)
        XCTAssertNotNil(UUID(uuidString: nonce))
        for target in ClientTarget.allCases { XCTAssertNoThrow(try ClientSnippetGenerator.generate(frozen, target: target)) }
        for target in CommandTarget.allCases { XCTAssertTrue(try CommandGenerator.generate(request, environment: nil, target: target).contains("X-Nonce")) }
        var workspace = Workspace.starter; hook.enabled = false; hook.source = "unfinished source for editing"
        workspace.requests[0].preHook = hook
        XCTAssertNoThrow(try WorkspaceFile.encode(workspace))
        workspace.requests[0].preHook?.enabled = true
        XCTAssertNoThrow(try WorkspaceFile.encode(workspace))
        XCTAssertThrowsError(try HookRuntime.execute(workspace.requests[0].preHook, request: request, variables: [:]))
    }

    func testUnsuccessfulEmptyAndCancelledReportsCannotLookSuccessful() throws {
        for cancelled in [false, true] {
            var report = RunReport(requestedSteps: 1); report.cancelled = cancelled
            let json = try XCTUnwrap(RunReportExporter.files(report, format: .json)["rill-run.json"])
            XCTAssertEqual((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["passed"] as? Bool, false)
            let xml = try XCTUnwrap(RunReportExporter.files(report, format: .junit)["rill-run.xml"])
            XCTAssertTrue(XMLParser(data: xml).parse())
            XCTAssertTrue(String(decoding: xml, as: UTF8.self).contains("failures=\"1\""))
            let allure = try RunReportExporter.files(report, format: .allure)
            XCTAssertTrue(try allure.values.contains { (try JSONSerialization.jsonObject(with: $0) as? [String: Any])?["status"] as? String == "failed" })
        }
    }
    func testMatrixBoundsAndInFlightCancellation() async throws {
        do {
            _ = try await MatrixRunner.run(requests: [], environments: [], concurrency: 1, configuration: RunConfiguration())
            XCTFail("Empty matrices must fail validation")
        } catch { XCTAssertTrue(error is WorkflowError) }
        let task = Task {
            try await CollectionRunner.run(requests: [RequestDraft()], environment: nil, configuration: RunConfiguration(), executor: { request, variables in
                try await Task.sleep(for: .seconds(60))
                return WorkflowStepResult(exchange: Self.exchange(request), variables: variables, stop: false)
            })
        }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        let cancelled = try await task.value
        XCTAssertTrue(cancelled.cancelled); XCTAssertFalse(cancelled.passed)
    }

    func testLoadConcurrencyIsBoundedAndCancellationMarksUnstartedWork() async throws {
        let probe = ConcurrencyProbe()
        var config = LoadConfiguration(); config.count = 12; config.concurrency = 3
        let result = try await LoadRunner.run(request: RequestDraft(), environment: nil, configuration: config, executor: { request, variables in
            await probe.enter()
            try await Task.sleep(for: .milliseconds(15))
            await probe.leave()
            return WorkflowStepResult(exchange: Self.exchange(request), variables: variables, stop: false)
        })
        let peak = await probe.maximum()
        XCTAssertTrue(result.passed); XCTAssertLessThanOrEqual(peak, 3); XCTAssertGreaterThan(peak, 1)
        let snapshot = config
        let task = Task {
            try await LoadRunner.run(request: RequestDraft(), environment: nil, configuration: snapshot, executor: { request, variables in
                try await Task.sleep(for: .seconds(60))
                return WorkflowStepResult(exchange: Self.exchange(request), variables: variables, stop: false)
            })
        }
        try await Task.sleep(for: .milliseconds(20)); task.cancel()
        let cancelled = try await task.value
        XCTAssertFalse(cancelled.passed); XCTAssertTrue(cancelled.cancelled)
        XCTAssertEqual(cancelled.samples.count, 12)
        XCTAssertTrue(cancelled.samples.contains { $0.state == .notRun })
    }

}
