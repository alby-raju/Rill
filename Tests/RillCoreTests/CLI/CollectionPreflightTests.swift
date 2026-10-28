import Foundation
import XCTest

@testable import RillCore

final class CollectionPreflightTests: XCTestCase {
    private func collection(_ items: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        var root = extra
        root["info"] = [
            "name": "fixture",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        ]
        root["item"] = items
        return try JSONSerialization.data(withJSONObject: root)
    }
    private func request(_ url: String) -> [String: Any] {
        ["name": "secret-request-label", "request": ["method": "GET", "url": url]]
    }
    func testEnvironmentPrecedenceAndNestedReferences() throws {
        let input = try collection(
            [request("{{base}}/path")],
            extra: [
                "variable": [["key": "base", "value": "{{missing}}"]]
            ])
        let env = try JSONSerialization.data(withJSONObject: [
            "_postman_variable_scope": "environment", "name": "fixture",
            "values": [
                ["key": "base", "value": "{{host}}"],
                ["key": "host", "value": "http://127.0.0.1:1"],
            ],
        ])
        XCTAssertTrue(try CollectionPreflight.inspect(collection: input, environment: env).passed)
        XCTAssertTrue(
            try CollectionPreflight.inspect(collection: input, overrides: ["base": ""]).passed)
        XCTAssertFalse(try CollectionPreflight.inspect(collection: input).passed)
    }
    func testScriptsAtEveryScopeBlockAndDoNotLeakSourceOrNames() throws {
        let event: [[String: Any]] = [
            [
                "listen": "prerequest",
                "script": ["exec": ["throw new Error('private-script-seed')"]],
            ]
        ]
        var leaf = request("http://127.0.0.1:1")
        leaf["event"] = event
        let input = try collection(
            [["name": "private-folder", "event": event, "item": [leaf]]], extra: ["event": event])
        let result = try CollectionPreflight.inspect(collection: input)
        XCTAssertEqual(result.requests, 1)
        XCTAssertEqual(result.scripts, 3)
        XCTAssertEqual(
            result.issues.filter { $0.code == "scripts.unsupported" }.map(\.location),
            ["/event/0", "/item/0/event/0", "/item/0/item/0/event/0"])
        let output = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for secret in ["private-script-seed", "private-folder", "secret-request-label"] {
            XCTAssertFalse(output.contains(secret))
        }
        XCTAssertFalse(result.passed)
    }
    func testDisabledVariablesCyclesAndMalformedEvents() throws {
        let input = try collection(
            [request("{{base}}")], extra: ["variable": [["key": "base", "value": "{{base}}"]]])
        XCTAssertFalse(try CollectionPreflight.inspect(collection: input).passed)
        let disabled = try collection(
            [request("{{base}}")],
            extra: ["variable": [["key": "base", "value": "secret", "disabled": true]]])
        XCTAssertFalse(try CollectionPreflight.inspect(collection: disabled).passed)
        let malformed = try collection([request("http://127.0.0.1:1")], extra: ["event": "wrong"])
        XCTAssertEqual(try CollectionPreflight.inspect(collection: malformed).requests, 1)
        XCTAssertTrue(
            try CollectionPreflight.inspect(collection: malformed).issues.contains {
                $0.code == "scripts.invalid"
            })
        XCTAssertThrowsError(try CollectionPreflight.inspect(collection: Data("{}".utf8)))
    }
    func testEmptyScriptsDoNotBlockButDynamicReferencesDo() throws {
        let input = try collection(
            [request("http://127.0.0.1:1")], extra: ["event": [["script": ["exec": ["  "]]]]])
        XCTAssertTrue(try CollectionPreflight.inspect(collection: input).passed)
        XCTAssertFalse(
            try CollectionPreflight.inspect(
                collection: collection([request("http://127.0.0.1:1/{{$guid}}")])
            ).passed)
    }
    func testDiagnosticRetentionAndExpansionBudgetAreBounded() throws {
        let event: [[String: Any]] = [["script": ["exec": ["pm.test('fixture', () => {})"]]]]
        let items = (0..<1100).map { _ -> [String: Any] in
            var row = request("http://127.0.0.1:1")
            row["event"] = event
            return row
        }
        let report = try CollectionPreflight.inspect(collection: collection(items))
        XCTAssertEqual(report.scripts, 1100)
        XCTAssertEqual(report.issueCount, 1100)
        XCTAssertEqual(report.issues.count, 1000)
        let many = String(repeating: "{{x}}", count: 100_001)
        let limited = try CollectionPreflight.inspect(
            collection: collection([request("http://127.0.0.1:1/" + many)]), overrides: ["x": "ok"])
        XCTAssertTrue(limited.issues.contains { $0.code == "variables.unresolved_cyclic_or_limit" })
        let literal: [String: Any] = [
            "name": "fixture",
            "request": [
                "method": "POST", "url": "http://127.0.0.1:1",
                "body": [
                    "mode": "raw", "raw": "{{" + String(repeating: " ", count: 100_000) + "literal",
                ],
            ],
        ]
        XCTAssertTrue(try CollectionPreflight.inspect(collection: collection([literal])).passed)

    }

}
