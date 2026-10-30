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
    func testFolderSelectionPreservesDescendantOrderAndInheritedAuthentication() throws {
        var outside = item("outside", "{{unresolved-outside}}")
        outside["event"] = [["script": ["exec": ["private-excluded-script"]]]]
        var overridden = item("second", "http://127.0.0.1:1/second")
        overridden["request"] = [
            "method": "POST", "url": "http://127.0.0.1:1/second", "auth": ["type": "noauth"],
        ]
        let input = try collection(
            [
                outside,
                [
                    "name": "Parent",
                    "auth": [
                        "type": "bearer", "bearer": [["key": "token", "value": "{{token}}"]],
                    ],
                    "item": [
                        outside,
                        [
                            "name": "Selected",
                            "item": [
                                item("first", "http://127.0.0.1:1/first"),
                                ["name": "Nested", "item": [overridden]],
                                item("third", "http://127.0.0.1:1/third"),
                            ],
                        ],
                    ],
                ],
            ], variables: [["key": "token", "value": "fixture-parent-token"]])
        let plan = try PostmanFileRun.prepare(collection: input, folder: "/Parent/Selected")
        XCTAssertEqual(plan.requests.map(\.name), ["first", "second", "third"])
        let first = try RequestEngine.prepare(
            plan.requests[0], environment: plan.environment, secrets: plan.secrets)
        XCTAssertEqual(
            first.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-parent-token")
        let second = try RequestEngine.prepare(
            plan.requests[1], environment: plan.environment, secrets: plan.secrets)
        XCTAssertNil(second.value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try PostmanFileRun.prepare(collection: input))
        let preflight = try CollectionPreflight.inspect(
            collection: input, folder: "/Parent/Selected")
        XCTAssertTrue(preflight.passed)
        XCTAssertTrue(preflight.folderSelected)
        XCTAssertEqual(preflight.requests, 3)
    }
    func testFolderScriptsAtEveryInheritedScopeRemainBlockedWithOriginalLocations() throws {
        let event: [[String: Any]] = [["script": ["exec": ["private-selected-script"]]]]
        for (scope, location) in [
            (0, "/event/0"), (1, "/item/1/event/0"),
            (2, "/item/1/item/1/event/0"), (3, "/item/1/item/1/item/0/event/0"),
        ] {
            var request = item("private-request", "http://127.0.0.1:1")
            if scope == 3 { request["event"] = event }
            var chosen: [String: Any] = ["name": "Selected", "item": [request]]
            if scope == 2 { chosen["event"] = event }
            var parent: [String: Any] = [
                "name": "Parent", "item": [["name": "excluded", "item": []], chosen],
            ]
            if scope == 1 { parent["event"] = event }
            let input = try collection([["name": "excluded", "item": []], parent])
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
            if scope == 0 { root["event"] = event }
            let bytes = try JSONSerialization.data(withJSONObject: root)
            let report = try CollectionPreflight.inspect(
                collection: bytes, folder: "/Parent/Selected")
            XCTAssertFalse(report.passed)
            XCTAssertEqual(report.scripts, 1)
            XCTAssertTrue(
                report.issues.contains {
                    $0.code == "scripts.unsupported" && $0.location == location
                })
            let diagnostics = try JSONEncoder().encode(report)
            XCTAssertFalse(String(decoding: diagnostics, as: UTF8.self).contains("private-"))
            XCTAssertThrowsError(
                try PostmanFileRun.prepare(collection: bytes, folder: "/Parent/Selected"))
        }
    }
    func testFolderPathsAreExactEscapedAndUnambiguous() throws {
        let leaf = item("fixture", "http://127.0.0.1:1")
        let input = try collection([
            ["name": "A/B~", "item": [["name": "日本語", "item": [leaf]]]],
            ["name": "duplicate", "item": [leaf]], ["name": "duplicate", "item": [leaf]],
            ["name": "empty", "item": []], leaf,
        ])
        let bom = Data([0xef, 0xbb, 0xbf]) + input
        XCTAssertEqual(
            try PostmanFileRun.prepare(collection: bom, folder: "/A~1B~0/日本語").requests.count, 1)
        for path in [
            "", "A/B~", "/A~2B", "/A~", "/A~́", "/" + String(repeating: "x", count: 4096),
            String(repeating: "/a", count: 33),
        ] {
            XCTAssertThrowsError(try PostmanFileRun.prepare(collection: input, folder: path)) {
                guard case PostmanFolderSelectionError.invalidPath = $0 else {
                    return XCTFail("Expected invalid path")
                }
            }
        }
        for path in ["/missing", "/duplicate", "/fixture", "/a~1B~0/日本語", "/A~1B~0/missing"] {
            XCTAssertThrowsError(try PostmanFileRun.prepare(collection: input, folder: path)) {
                guard case PostmanFolderSelectionError.missingOrAmbiguous = $0 else {
                    return XCTFail("Expected missing or ambiguous folder")
                }
            }
        }
        let empty = try CollectionPreflight.inspect(collection: input, folder: "/empty")
        XCTAssertFalse(empty.passed)
        XCTAssertTrue(empty.issues.contains { $0.code == "collection.empty" })
        let literal = try collection([["name": "~1", "item": [leaf]]])
        XCTAssertEqual(
            try PostmanFileRun.prepare(collection: literal, folder: "/~01").requests.count, 1)
        var nested = leaf
        for _ in 0..<32 { nested = ["name": "a", "item": [nested]] }
        XCTAssertEqual(
            try PostmanFileRun.prepare(
                collection: collection([nested]), folder: String(repeating: "/a", count: 32)
            ).requests.count, 1)
    }
    func testSelectedFolderRetainsAncestorTransportAndVariableBlockers() throws {
        for setting in ["protocolProfileBehavior", "proxy", "certificate", "variable"] {
            var parent: [String: Any] = [
                "name": "Parent",
                "item": [["name": "Selected", "item": [item("leaf", "http://127.0.0.1:1")]]],
            ]
            parent[setting] = setting == "variable" ? [["key": "x", "value": "y"]] : [:]
            let input = try collection([["name": "excluded", "item": []], parent])
            let checked = try CollectionPreflight.inspect(
                collection: input, folder: "/Parent/Selected")
            XCTAssertFalse(checked.passed)
            if setting != "variable" {
                XCTAssertTrue(
                    checked.issues.contains {
                        $0.code == "transport.settings_not_applied"
                            && $0.location == "/item/1/" + setting
                    })
            }
            XCTAssertThrowsError(
                try PostmanFileRun.prepare(collection: input, folder: "/Parent/Selected"))
        }
    }
    func testSelectedFolderStillValidatesAllSelectedRequestsBeforeRunning() throws {
        let input = try collection([
            [
                "name": "folder",
                "item": [
                    item("first", "http://127.0.0.1:1"), item("later", "{{bad}}"),
                ],
            ]
        ])
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(
                collection: input, overrides: ["bad": "file:///private/fixture"], folder: "/folder")
        )
        let unresolved = try CollectionPreflight.inspect(collection: input, folder: "/folder")
        XCTAssertTrue(
            unresolved.issues.contains {
                $0.code == "variables.unresolved_cyclic_or_limit"
                    && $0.location == "/item/0/item/1/request"
            })
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
