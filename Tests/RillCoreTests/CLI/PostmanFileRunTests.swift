import XCTest

@testable import RillCore

final class PostmanFileRunTests: XCTestCase {
    private func item(_ name: String, _ url: String) -> [String: Any] {
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
    func testDepthFirstOrderAndEnvironmentPrecedence() throws {
        let input = try collection(
            [
                item("one", "{{base}}/one"),
                [
                    "name": "folder",
                    "item": [item("two", "{{base}}/two"), item("three", "{{base}}/three")],
                ],
            ],
            variables: [
                ["key": "base", "value": "{{missing}}"], ["key": "empty", "value": "old"],
            ])
        let environment = try JSONSerialization.data(withJSONObject: [
            "_postman_variable_scope": "environment",
            "values": [
                ["key": "base", "value": "http://127.0.0.1:1"],
                ["key": "empty", "value": "environment"],
                ["key": "disabled", "value": "ignored", "enabled": false],
            ],
        ])
        let plan = try PostmanFileRun.prepare(
            collection: input, environment: environment, overrides: ["empty": ""])
        XCTAssertEqual(plan.requests.map(\.name), ["one", "two", "three"])
        let variables = WorkflowEngine.variables(in: plan.environment)
        XCTAssertEqual(variables["base"], "http://127.0.0.1:1")
        XCTAssertEqual(variables["empty"], "")
        XCTAssertNil(variables["disabled"])
    }
    func testSecretTypedVariablesResolveOnlyFromTransientInput() throws {
        var request = item("secret", "http://127.0.0.1:1")
        request["request"] = [
            "method": "POST", "url": "http://127.0.0.1:1",
            "header": [["key": "X-Token", "value": "{{token}}"]],
        ]
        let plan = try PostmanFileRun.prepare(
            collection: collection(
                [request],
                variables: [["key": "token", "value": "fixture-secret", "type": "secret"]]))
        let prepared = try RequestEngine.prepare(
            plan.requests[0], environment: plan.environment, secrets: plan.secrets)
        XCTAssertEqual(prepared.value(forHTTPHeaderField: "X-Token"), "fixture-secret")
        XCTAssertTrue(plan.environment.variables[0].value.hasPrefix("{{secret:"))
        XCTAssertThrowsError(try plan.secrets.resolve("unrelated-native-secret"))
    }
    func testScriptsAndMultipartInputsAreBlockedBeforeExecution() throws {
        var scripted = item("script", "http://127.0.0.1:1")
        scripted["event"] = [["script": ["exec": ["pm.test('fixture', () => {})"]]]]
        XCTAssertThrowsError(try PostmanFileRun.prepare(collection: collection([scripted]))) {
            error in
            guard case PostmanFileRunError.blocked(let report) = error else {
                return XCTFail("Unexpected error")
            }
            XCTAssertTrue(report.issues.contains { $0.code == "scripts.unsupported" })
        }
        let multipart: [String: Any] = [
            "name": "multipart",
            "request": [
                "method": "POST", "url": "http://127.0.0.1:1",
                "body": [
                    "mode": "formdata",
                    "formdata": [["key": "text", "value": "value", "type": "text"]],
                ],
            ],
        ]
        XCTAssertThrowsError(try PostmanFileRun.prepare(collection: collection([multipart])))
    }
    func testLaterInvalidExpandedURLBlocksTheWholePlan() throws {
        let input = try collection([
            item("valid", "http://127.0.0.1:1"), item("invalid", "{{bad}}"),
        ])
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(
                collection: input, overrides: ["bad": "file:///private/fixture"]))
    }
    func testInputVariableLimitsAreCheckedBeforeExecution() throws {
        let input = try collection([item("fixture", "http://127.0.0.1:1")])
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(collection: input, overrides: ["": "value"]))
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(
                collection: input, overrides: ["x": String(repeating: "x", count: 1024 * 1024 + 1)])
        )
        let oversized = Dictionary(uniqueKeysWithValues: (0..<1025).map { ("key\($0)", "") })
        XCTAssertThrowsError(try PostmanFileRun.prepare(collection: input, overrides: oversized))
    }
    func testCancelledPreparationStopsWithoutParsing() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PostmanFileRun.prepare(collection: Data())
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled preparation succeeded")
        } catch is CancellationError {}
    }
    func testRunAddsExplicitHTTPStatusChecksAndRetries() async throws {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("Fixture required")
        }
        let good = try PostmanFileRun.prepare(
            collection: collection([item("good", base + "/echo")]))
        let passed = try await good.run(configuration: RunConfiguration())
        XCTAssertTrue(passed.passed)
        XCTAssertEqual(passed.outcomes[0].checks.count, 1)
        XCTAssertTrue(passed.outcomes[0].checks.allSatisfy(\.passed))
        let bad = try PostmanFileRun.prepare(
            collection: collection([item("bad", base + "/oauth/token")]))
        var configuration = RunConfiguration()
        configuration.retries = 1
        let failed = try await bad.run(configuration: configuration)
        XCTAssertFalse(failed.passed)
        XCTAssertEqual(failed.outcomes.count, 2)
        XCTAssertTrue(failed.outcomes.allSatisfy { $0.status == 400 && $0.state == .failed })
    }
}
