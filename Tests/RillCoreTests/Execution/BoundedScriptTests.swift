import Foundation
import XCTest

@testable import RillCore

private actor ScriptExportCapture {
    var values: [String: String]?
    func save(_ values: [String: String]) { self.values = values }
}

@MainActor final class BoundedScriptTests: XCTestCase {
    func testGrammarParsesOnlyFiniteOperationsAndPreservesStringEscapes() throws {
        var parser = try ScriptParser(
            #"pm.environment.set('token', 'line\n\uD83C\uDF0A'); pm.globals.unset('old'); if (pm.variables.get('run') === 'true') { pm.execution.setNextRequest('next'); } else { pm.execution.setNextRequest(null); } pm.test('private label', function () { pm.response.to.have.status(201); });"#,
            phase: .test)
        let program = try parser.parse()
        XCTAssertEqual(program.writes, ["token", "old"])
        XCTAssertEqual(program.branches, ["next"])
        guard case .set(.environment, "token", .literal(let text)) = program.operations.first else {
            return XCTFail()
        }
        XCTAssertEqual(text, "line\n🌊")
        for input in [
            "eval('private')", "while (true) {}", "pm.sendRequest('http://private.invalid');",
            "pm.environment.set('x', `private ${value}`);", "pm.environment.set('x', 123);",
            "pm.environment.set('x', 'ok'); unknown('private');",
            "pm.test('x', () => { pm.environment.set('x', 'y'); });",
            "pm.environment.set('x', '\\uD800');", "if (true) {}",
        ] {
            XCTAssertThrowsError(try ScriptParser(input, phase: .test).parsed())
        }
        XCTAssertThrowsError(
            try ScriptParser(
                "pm.test('x', () => { pm.response.to.have.status(200); });", phase: .prerequest
            ).parsed())
        XCTAssertThrowsError(try ScriptParser("pm.execution.skipRequest();", phase: .test).parsed())
    }

    private func event(_ text: String, phase: String = "test") -> [String: Any] {
        ["listen": phase, "script": ["exec": [text]]]
    }
    private func request(
        _ name: String, url: String, events: [[String: Any]] = [], headers: [[String: String]] = []
    ) -> [String: Any] {
        [
            "name": name, "request": ["method": "GET", "url": url, "header": headers],
            "event": events,
        ]
    }
    private func collection(_ items: [[String: Any]], events: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "info": [
                "name": "Synthetic",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ], "item": items, "event": events,
        ])
    }
    private func base() throws -> String {
        guard let value = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("HTTP fixture required")
        }
        return value
    }
    private func echoedHeaders(_ report: RunReport) throws -> [String: String] {
        let data = try XCTUnwrap(report.outcomes.last?.retainedBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["headers"] as? [String: String])
    }

    func testTypedAssertionsKeepCallbackGroupingAndRedactValues() async throws {
        let data = try collection([
            request(
                "Scalars", url: base() + "/script-scalars",
                events: [
                    event(
                        """
                        const document = pm.response.json();
                        pm.test('private-label', () => {
                            const payload = pm.response.json();
                            pm.response.to.have.header('x-fixture');
                            pm.expect(pm.response.headers.get('X-Fixture')).to.equal('Rill');
                            pm.expect(payload.n).to.eql(42);
                            pm.expect(document.ok).to.equal(true);
                            pm.expect(pm.response.json().empty).to.eql(null);
                            pm.expect(pm.response.json().zero).to.equal(0);
                        });
                        pm.test('typed failure', () => {
                            pm.expect(pm.response.json().text).to.eql(42);
                            pm.expect(pm.response.json().empty).to.equal(null);
                        });
                        pm.test('signed zero', () => {
                            pm.expect(pm.response.json().zero).to.eql(0);
                        });
                        pm.test('missing differs from null', () => {
                            pm.expect(pm.response.json().missing).to.equal(null);
                        });
                        pm.test('next callback still runs', () => {
                            pm.response.to.have.status(200);
                        });
                        """)
                ])
        ])
        let plan = try PostmanFileRun.prepare(collection: data, translateScripts: true)
        let report = try await plan.run(configuration: RunConfiguration())
        XCTAssertEqual(
            report.outcomes.first?.checks.map(\.passed), [true, false, false, false, true])
        XCTAssertFalse(report.passed)
        let bytes = try XCTUnwrap(RunReportExporter.files(report, format: .json).values.first)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-label"))
        XCTAssertThrowsError(
            try ScriptParser(
                "pm.test('x', () => { pm.expect(pm.response.json().n).to.eql({ a: 1 }); });",
                phase: .test
            ).parsed())
    }

    func testInheritedPreAndPostOrderScopesExtractionAndFailedTestMutations() async throws {
        let base = try base()
        let data = try collection(
            [
                [
                    "name": "Folder",
                    "event": [event("pm.environment.set('order', 'folder');", phase: "prerequest")],
                    "item": [
                        request(
                            "First", url: base + "/json",
                            events: [
                                event(
                                    "pm.environment.set('order', 'request');", phase: "prerequest"),
                                event(
                                    "pm.environment.set('token', pm.response.headers.get('X-Fixture')); pm.test('private fail', () => { pm.response.to.have.status(500); }); pm.environment.set('after', 'private-after-failure');"
                                ),
                            ]),
                        request(
                            "Echo", url: base + "/echo",
                            headers: [
                                ["key": "X-Token", "value": "{{token}}"],
                                ["key": "X-After", "value": "{{after}}"],
                                ["key": "X-Order", "value": "{{order}}"],
                            ]),
                    ],
                ]
            ], events: [event("pm.environment.set('order', 'collection');", phase: "prerequest")])
        XCTAssertThrowsError(try PostmanFileRun.prepare(collection: data))
        let plan = try PostmanFileRun.prepare(collection: data, translateScripts: true)
        var configuration = RunConfiguration()
        configuration.stopOnFailure = false
        let report = try await plan.run(configuration: configuration)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.outcomes.map(\.state), [.failed, .passed])
        let headers = try echoedHeaders(report)
        XCTAssertEqual(
            headers.first { $0.key.lowercased() == "x-after" }?.value, "private-after-failure")
        XCTAssertEqual(headers.first { $0.key.lowercased() == "x-order" }?.value, "folder")
        for format in RunReportFormat.allCases {
            for bytes in try RunReportExporter.files(report, format: format).values {
                XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-"))
            }
        }
    }

    func testPreRequestHeaderEditsAreOrderedLiteralAndScopedToOneRequest() async throws {
        let base = try base()
        let data = try collection([
            request(
                "Mutated", url: base + "/echo",
                events: [
                    event(
                        """
                        pm.environment.set('token', 'private-token');
                        pm.request.headers.upsert({value: 'Bearer ' + pm.environment.get('token'), key: 'authorization'});
                        pm.request.headers.remove('x-remove');
                        pm.request.headers.add({key: 'X-Literal', value: '{{unresolved}}'});
                        """, phase: "prerequest")
                ],
                headers: [["key": "X-Remove", "value": "old"]]),
            request("Untouched", url: base + "/echo"),
        ])
        let planned = try PostmanFileRun.prepare(
            collection: data, translateScripts: true, planningOnly: true)
        XCTAssertEqual(planned.deferredRequestPositions, [0, 1])
        let executable = try PostmanFileRun.prepare(collection: data, translateScripts: true)
        let report = try await executable.run(configuration: RunConfiguration())
        XCTAssertTrue(report.passed)
        let headers = try report.outcomes.map { outcome in
            let body = try XCTUnwrap(outcome.retainedBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try XCTUnwrap(object["headers"] as? [String: String])
        }
        XCTAssertEqual(
            headers[0].first { $0.key.lowercased() == "authorization" }?.value,
            "Bearer private-token")
        XCTAssertNil(headers[0].first { $0.key.lowercased() == "x-remove" })
        XCTAssertEqual(
            headers[0].first { $0.key.lowercased() == "x-literal" }?.value, "{{unresolved}}")
        XCTAssertNil(headers[1].first { $0.key.lowercased() == "authorization" })
        XCTAssertNil(headers[1].first { $0.key.lowercased() == "x-literal" })
        let json = try XCTUnwrap(RunReportExporter.files(report, format: .json).values.first)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("private-token"))
    }

    func testHeaderEditsRejectUnsafeNamesAndUnrepresentableDuplicates() async throws {
        for script in [
            "pm.request.headers.remove('Host');",
            "pm.request.headers.upsert({key: 'Content-Length', value: '4'});",
            "pm.request.headers.add({key: 'X-Ok', value: 42});",
        ] {
            XCTAssertThrowsError(try ScriptParser(script, phase: .prerequest).parsed())
        }
        XCTAssertThrowsError(
            try ScriptParser("pm.request.headers.remove('X-Ok');", phase: .test).parsed())
        let data = try collection([
            request(
                "Duplicate", url: base() + "/echo",
                events: [
                    event(
                        "pm.request.headers.add({key: 'x-existing', value: 'new'});",
                        phase: "prerequest")
                ],
                headers: [["key": "X-Existing", "value": "old"]])
        ])
        let plan = try PostmanFileRun.prepare(collection: data, translateScripts: true)
        let report = try await plan.run(configuration: RunConfiguration())
        XCTAssertEqual(report.outcomes.first?.failure, "invalidRequest")
        XCTAssertNil(report.outcomes.first?.status)
    }

    func testSkipAndCrossFolderBranchHaveExplicitRunOutcomes() async throws {
        let base = try base()
        let data = try collection([
            [
                "name": "A",
                "item": [
                    request(
                        "Skip", url: base + "/json",
                        events: [event("pm.execution.skipRequest();", phase: "prerequest")]),
                    request(
                        "Branch", url: base + "/json",
                        events: [event("pm.execution.setNextRequest('Target');")]),
                ],
            ],
            request("Unvisited", url: base + "/json"),
            [
                "name": "B",
                "item": [
                    request(
                        "Target", url: base + "/json",
                        events: [
                            event(
                                "pm.test('status', function () { pm.response.to.have.status(200); }); pm.execution.setNextRequest(null);"
                            )
                        ])
                ],
            ],
        ])
        let plan = try PostmanFileRun.prepare(collection: data, translateScripts: true)
        let report = try await plan.run(configuration: RunConfiguration())
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.outcomes.map(\.state), [.skipped, .passed, .passed, .notRun])
        XCTAssertNil(report.outcomes.first?.status)
        XCTAssertNil(report.outcomes.first?.retainedBody)
        let onlySkip = try PostmanFileRun.prepare(
            collection: collection([
                request(
                    "Skip", url: base + "/json",
                    events: [event("pm.execution.skipRequest();", phase: "prerequest")])
            ]), translateScripts: true)
        let skipped = try await onlySkip.run(configuration: RunConfiguration())
        XCTAssertTrue(skipped.passed)
        let xml = try XCTUnwrap(RunReportExporter.files(skipped, format: .junit).values.first)
        XCTAssertTrue(String(decoding: xml, as: UTF8.self).contains("skipped=\"1\""))
    }

    func testUnsupportedLaterSourceAndAmbiguousBranchesBlockBeforeAnyRun() throws {
        for source in [
            "pm.sendRequest('http://private.invalid');", "pm.execution.setNextRequest('Missing');",
            "pm.environment.set('x', 'v'); eval('private');",
        ] {
            let data = try collection([
                request("First", url: "http://127.0.0.1:1"),
                request("Later", url: "http://127.0.0.1:1", events: [event(source)]),
            ])
            XCTAssertThrowsError(
                try PostmanFileRun.prepare(collection: data, translateScripts: true))
            let checked = try CollectionPreflight.inspect(collection: data, translateScripts: true)
            XCTAssertFalse(checked.passed)
            XCTAssertFalse(
                String(decoding: try JSONEncoder().encode(checked), as: UTF8.self).contains(
                    "private"))
        }
        let misplaced = try collection([
            [
                "name": "Malformed",
                "request": [
                    "method": "GET", "url": "http://127.0.0.1:1",
                    "event": [event("privateUnknown();")],
                ],
            ]
        ])
        XCTAssertFalse(try CollectionPreflight.inspect(collection: misplaced).passed)
        XCTAssertThrowsError(try PostmanFileRun.prepare(collection: misplaced))
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(collection: misplaced, translateScripts: true))
    }

    func testTranslationInventoryLimitsAndOverridePolicyStayExplicit() throws {
        let source = try collection([
            request(
                "One", url: "http://127.0.0.1:1",
                events: [event("pm.environment.set('x', 'value');")])
        ])
        let report = try CollectionPreflight.inspect(
            collection: source, includeScriptInventory: true, translateScripts: true)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.scriptInventory?.sources.first?.disposition, .translated)
        XCTAssertEqual(report.scriptInventory?.translatedForeignConstructs, 1)
        XCTAssertEqual(report.scriptTranslation?.translatedOperations, 1)
        XCTAssertFalse(
            try CollectionPreflight.inspect(
                collection: source, overrides: ["x": "cli"], translateScripts: true
            ).passed)
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(
                collection: source, overrides: ["x": "cli"], translateScripts: true))
        let excessive = String(
            repeating: "pm.test('x', () => { pm.response.to.have.status(200); });", count: 513)
        let tooMuch = try collection([
            request("One", url: "http://127.0.0.1:1", events: [event(excessive)])
        ])
        XCTAssertThrowsError(
            try PostmanFileRun.prepare(collection: tooMuch, translateScripts: true))
        let deep =
            String(repeating: "if ('yes') {", count: 17) + "pm.environment.set('x', 'v');"
            + String(repeating: "}", count: 17)
        XCTAssertThrowsError(try ScriptParser(deep, phase: .test).parsed())
    }

    func testUnicodeConditionsAndBranchNamesUseExactBytes() async throws {
        let base = try base()
        let source = try collection([
            request(
                "Branch", url: base + "/json",
                events: [
                    event(
                        "if ('é' === 'e\\u0301') { pm.execution.setNextRequest('Wrong'); } else { pm.execution.setNextRequest('é'); }"
                    )
                ]),
            request("Wrong", url: base + "/json"),
            request("e\u{0301}", url: base + "/json"),
            request(
                "é", url: base + "/json", events: [event("pm.execution.setNextRequest(null);")]),
        ])
        let plan = try PostmanFileRun.prepare(collection: source, translateScripts: true)
        let report = try await plan.run(configuration: RunConfiguration())
        XCTAssertTrue(report.passed)
        XCTAssertEqual(
            report.outcomes.filter { $0.status != nil }.map(\.requestID),
            [plan.requests[0].id, plan.requests[3].id])
    }

    func testIterationRowsResetScopesAndCancelledRunsDoNotExport() async throws {
        let base = try base()
        let source = try collection([
            request(
                "Echo", url: base + "/echo",
                events: [
                    event(
                        "if (!pm.environment.get('carry')) { pm.environment.set('carry', 'first'); } else { pm.environment.set('carry', 'leaked'); }",
                        phase: "prerequest")
                ], headers: [["key": "X-Carry", "value": "{{carry}}"]])
        ])
        let data = try IterationData(rows: [["row": "one"], ["row": "two"]])
        let plan = try PostmanFileRun.prepare(
            collection: source, iterationData: data, translateScripts: true)
        var config = RunConfiguration()
        config.iterations = 2
        let capture = ScriptExportCapture()
        let report = try await plan.run(
            configuration: config, exportEnvironment: { await capture.save($0) })
        XCTAssertTrue(report.passed)
        let final = await capture.values
        XCTAssertEqual(final?["carry"], "first")
        XCTAssertEqual(final?["row"], "two")
        let persistent = try PostmanFileRun.prepare(collection: source, translateScripts: true)
        let flowed = try await persistent.run(configuration: config)
        XCTAssertEqual(
            try echoedHeaders(flowed).first { $0.key.lowercased() == "x-carry" }?.value, "leaked")
        let cancelledCapture = ScriptExportCapture()
        let task = Task {
            try await plan.run(
                configuration: config, exportEnvironment: { await cancelledCapture.save($0) })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation during initial data validation")
        } catch is CancellationError {}
        let missing = await cancelledCapture.values
        XCTAssertNil(missing)
    }

    func testTransientSecretCopiesAreVisibleOnlyInExplicitRawOutputs() async throws {
        let base = try base()
        let source = try collection([
            request(
                "Echo", url: base + "/echo",
                events: [
                    event(
                        "pm.environment.set('alias', pm.environment.get('token'));",
                        phase: "prerequest")
                ], headers: [["key": "X-Alias", "value": "{{alias}}"]])
        ])
        let environment = try JSONSerialization.data(withJSONObject: [
            "_postman_variable_scope": "environment",
            "values": [["key": "token", "value": "private-runtime-secret", "type": "secret"]],
        ])
        let plan = try PostmanFileRun.prepare(
            collection: source, environment: environment, translateScripts: true)
        let capture = ScriptExportCapture()
        let report = try await plan.run(
            configuration: RunConfiguration(), exportEnvironment: { await capture.save($0) })
        XCTAssertTrue(report.passed)
        XCTAssertEqual(
            try echoedHeaders(report).first { $0.key.lowercased() == "x-alias" }?.value,
            "private-runtime-secret")
        let raw = await capture.values
        XCTAssertEqual(raw?["alias"], "private-runtime-secret")
        for format in RunReportFormat.allCases {
            for bytes in try RunReportExporter.files(report, format: format).values {
                XCTAssertFalse(
                    String(decoding: bytes, as: UTF8.self).contains("private-runtime-secret"))
            }
        }
    }
}

private extension ScriptParser {
    func parsed() throws -> ScriptProgram {
        var parser = self
        return try parser.parse()
    }
}
