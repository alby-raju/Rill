import Foundation
import XCTest

@testable import RillCore

@MainActor final class ScriptInventoryTests: XCTestCase {
    private func event(_ source: [String], phase: String = "test", disabled: Bool = false)
        -> [String: Any]
    {
        ["listen": phase, "disabled": disabled, "script": ["exec": source]]
    }
    private func request(events: [[String: Any]] = []) -> [String: Any] {
        [
            "name": "private-request", "event": events,
            "request": ["method": "GET", "url": "http://127.0.0.1:1/private-url"],
        ]
    }
    private func collection(_ items: [[String: Any]], events: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "info": [
                "name": "private-collection",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ],
            "event": events, "item": items,
        ])
    }

    func testInheritanceAndExactSelectionRetainOriginalSourceLocations() throws {
        let input = try collection(
            [
                [
                    "name": "Excluded", "event": [event(["pm.sendRequest('private-url')"])],
                    "item": [request()],
                ],
                [
                    "name": "Selected",
                    "item": [
                        ["name": "Other", "item": [request()]],
                        [
                            "name": "Child",
                            "event": [
                                event(["pm.environment.set('private-name','private-value')"])
                            ],
                            "item": [
                                request(events: [event(["pm.test('private-label', () => {})"])]),
                                request(),
                            ],
                        ],
                    ],
                ],
            ],
            events: [
                event(
                    ["pm.variables.set('private-name','private-value')"], phase: "prerequest",
                    disabled: true)
            ])
        let result = try ScriptCompatibilityInventory.inspect(
            collection: input, folder: "/Selected/Child")
        XCTAssertEqual(result.requests, 2)
        XCTAssertEqual(result.sourceCount, 3)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.sources.map(\.scope), [.collection, .folder, .request])
        XCTAssertEqual(result.sources.map(\.phase), [.prerequest, .test, .test])
        XCTAssertEqual(result.sources.map(\.affectedRequests), [2, 2, 1])
        XCTAssertEqual(
            result.sources.map(\.location),
            [
                "/event/0", "/item/1/item/1/event/0", "/item/1/item/1/item/0/event/0",
            ])
        XCTAssertTrue(result.sources[0].declaredDisabled)
        let bytes = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private-"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("runtime.http"))
        let preflight = try CollectionPreflight.inspect(
            collection: input, folder: "/Selected/Child", includeScriptInventory: true)
        XCTAssertFalse(preflight.passed)
        XCTAssertEqual(preflight.scripts, 3)
        XCTAssertEqual(preflight.scriptInventory?.sourceCount, 3)
    }

    func testLexicalHintsSkipCommentsAndStringsAndRetainJoinedSourceCoordinates() throws {
        let input = try collection(
            [request()],
            events: [
                event([
                    "// pm.sendRequest('private-url')",
                    "/* pm.vault.get('private-value') */",
                    "const text = \"pm.expect('private-value')\";",
                    "  pm.environment.set('private-name', 'private-value');",
                    "pm.test('private-label', function () { pm.response.to.have.status(200); });",
                    "pm.response.json(); pm.execution.setNextRequest('private-target');",
                    "require('private-module'); await pm.vault.get('private-name');",
                ])
            ])
        let inventory = try ScriptCompatibilityInventory.inspect(collection: input)
        let source = try XCTUnwrap(inventory.sources.first)
        XCTAssertEqual(source.disposition, .unsupported)
        XCTAssertEqual(
            source.features.map(\.code),
            [
                "variable.environment.write", "assertion.test", "assertion.status", "response.json",
                "workflow.next", "runtime.module", "syntax.async", "runtime.vault",
            ])
        XCTAssertEqual(source.features.first?.line, 4)
        XCTAssertEqual(source.features.first?.byteColumn, 3)
        XCTAssertEqual(source.features[1].line, 5)
        XCTAssertEqual(source.features[1].byteColumn, 1)
        XCTAssertEqual(inventory.supportedForeignConstructs, 0)
        XCTAssertEqual(inventory.translatedForeignConstructs, 0)
        let mixedNewlines = try collection(
            [request()],
            events: [
                event([
                    "// private\rpm.test('x', () => {});\r\n  pm.variables.set('x', 'y');"
                ])
            ])
        let coordinates = try ScriptCompatibilityInventory.inspect(collection: mixedNewlines)
        XCTAssertEqual(coordinates.sources.first?.features.map(\.line), [2, 3])
        XCTAssertEqual(coordinates.sources.first?.features.map(\.byteColumn), [1, 3])
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(inventory), as: UTF8.self).contains(
                "private-"))
    }

    func testOpaqueSyntaxNeverLooksTranslatedOrFullyInspected() throws {
        for source in [
            "const r = /pm.sendRequest('private')/; pm.test('x', () => {});",
            "const t = `private ${pm.environment.get('private')}`;",
            #"pm.\u0065nvironment.set('private', 'private');"#,
            "/* private unterminated comment", "'private unterminated string",
        ] {
            let input = try collection([request()], events: [event([source])])
            let inventory = try ScriptCompatibilityInventory.inspect(collection: input)
            XCTAssertFalse(inventory.complete)
            XCTAssertEqual(inventory.sources.first?.coverage, .partial)
            XCTAssertEqual(inventory.sources.first?.disposition, .unsupported)
            XCTAssertFalse(
                try CollectionPreflight.inspect(collection: input, includeScriptInventory: true)
                    .passed)
        }
    }

    func testUnknownSourceRemoteSourceEmptyBlocksAndMalformedEventsAreExplicit() throws {
        let sources: [[String: Any]] = [
            event(["unknownPrivateFunction('private-value');"]), event(["  ", "\t"]),
            ["listen": "private-phase", "script": ["src": "https://private.invalid/script.js"]],
            ["script": "private-invalid"],
        ]
        let input = try collection([request()], events: sources)
        let inventory = try ScriptCompatibilityInventory.inspect(collection: input)
        XCTAssertEqual(
            inventory.sources.map(\.disposition), [.unsupported, .empty, .unsupported, .invalid])
        XCTAssertEqual(inventory.sources[2].phase, .other)
        XCTAssertTrue(inventory.sources[2].features.contains { $0.code == "source.external" })
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(inventory), as: UTF8.self).contains("private")
        )
        let empty = try collection([request()], events: [event([" "])])
        XCTAssertTrue(
            try CollectionPreflight.inspect(collection: empty, includeScriptInventory: true).passed)
        let normal = try CollectionPreflight.inspect(collection: empty)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(normal), as: UTF8.self).contains(
                "scriptInventory"))
    }

    func testSourceFeatureAndByteBudgetsAreVisibleAndBounded() throws {
        let many = try collection(
            [request()], events: (0..<1002).map { _ in event(["pm.test('x', () => {});"]) })
        let inventory = try ScriptCompatibilityInventory.inspect(collection: many)
        XCTAssertEqual(inventory.sourceCount, 1002)
        XCTAssertEqual(inventory.sources.count, 1000)
        XCTAssertEqual(inventory.omittedSources, 2)
        XCTAssertFalse(inventory.complete)
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(inventory)) as? [String: Any])
        XCTAssertEqual(encoded["complete"] as? Bool, false)
        XCTAssertEqual(encoded["omittedSources"] as? Int, 2)
        let large = try collection(
            [request()], events: [event([String(repeating: "x", count: 1024 * 1024 + 1)])])
        let limited = try ScriptCompatibilityInventory.inspect(collection: large)
        XCTAssertFalse(limited.complete)
        XCTAssertEqual(limited.sources.first?.coverage, .limited)
        XCTAssertEqual(limited.sources.first?.features.first?.code, "analysis.limit")
        let calls = try collection(
            [request()], events: [event([String(repeating: "pm.test();", count: 5000)])])
        let features = try ScriptCompatibilityInventory.inspect(collection: calls)
        XCTAssertFalse(features.complete)
        XCTAssertEqual(features.sources.first?.features.count, 4000)
        let tokens = try collection(
            [request()], events: [event([String(repeating: "x;", count: 50_001)])])
        let tokenLimited = try ScriptCompatibilityInventory.inspect(collection: tokens)
        XCTAssertFalse(tokenLimited.complete)
        XCTAssertEqual(tokenLimited.sources.first?.features.last?.code, "analysis.limit")
        let bytes = try collection(
            [request()],
            events: (0..<5).map { _ in
                event([String(repeating: "x", count: 1024 * 1024)])
            })
        let byteLimited = try ScriptCompatibilityInventory.inspect(collection: bytes)
        XCTAssertFalse(byteLimited.complete)
        XCTAssertEqual(byteLimited.sources.last?.features.first?.code, "analysis.limit")
    }

    func testCancellationStopsOfflineInspection() async throws {
        let input = try collection([request()], events: [event(["pm.test('x', () => {});"])])
        let task = Task { try ScriptCompatibilityInventory.inspect(collection: input) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testCLIInventoryIsOptInRedactedAndCannotEnableExecution() async throws {
        guard let executable = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("CLI fixture required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("private-path with spaces.json")
        let input = try collection(
            [request()],
            events: [
                event(
                    [
                        "pm.environment.set('private-key','private-value');",
                        "pm.test('private-label', () => { throw new Error('private-error'); });",
                    ], disabled: true)
            ])
        try input.write(to: file)
        for flags in [["--json"], ["--detail"], ["--quiet"]] {
            let result = try await BoundedProcess.run(
                executable: URL(fileURLWithPath: executable),
                arguments: ["preflight", file.path, "--script-inventory"] + flags)
            XCTAssertEqual(result.status, 2)
            XCTAssertEqual(try Data(contentsOf: file), input)
            XCTAssertFalse(
                String(decoding: result.output + result.diagnostics, as: UTF8.self).contains(
                    "private-"))
            if flags == ["--json"] {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: result.output) as? [String: Any])
                XCTAssertEqual(object["sendsRequests"] as? Bool, false)
                XCTAssertEqual(object["passed"] as? Bool, false)
                let checks = try XCTUnwrap(object["checks"] as? [String: Any])
                let inventory = try XCTUnwrap(checks["scriptInventory"] as? [String: Any])
                XCTAssertEqual(inventory["strategy"] as? String, "foreign-source-blocked")
                XCTAssertEqual(inventory["supportedForeignConstructs"] as? Int, 0)
                XCTAssertEqual(inventory["complete"] as? Bool, true)
                XCTAssertEqual(inventory["omittedSources"] as? Int, 0)
            } else if flags == ["--quiet"] {
                XCTAssertTrue(result.output.isEmpty)
            }
        }
        for arguments in [
            ["run", file.path], ["doctor"], ["request", "GET", "http://127.0.0.1:1"],
        ] {
            let result = try await BoundedProcess.run(
                executable: URL(fileURLWithPath: executable),
                arguments: arguments + ["--script-inventory"])
            XCTAssertEqual(result.status, 2)
            XCTAssertTrue(result.output.isEmpty)
        }
        let legacy = try await BoundedProcess.run(
            executable: URL(fileURLWithPath: executable),
            arguments: ["preflight", file.path, "--json"])
        XCTAssertEqual(legacy.status, 2)
        XCTAssertFalse(String(decoding: legacy.output, as: UTF8.self).contains("scriptInventory"))
    }
}
