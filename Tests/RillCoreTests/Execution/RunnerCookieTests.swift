import Foundation
import XCTest

@testable import RillCore

@MainActor final class RunnerCookieTests: XCTestCase {
    private func requests() throws -> [RequestDraft] {
        guard let base = ProcessInfo.processInfo.environment["RILL_TEST_BASE_URL"] else {
            throw XCTSkip("HTTP fixture required")
        }
        return ["/cookie/set", "/echo", "/cookie/expire", "/echo"].map { path in
            var request = RequestDraft()
            request.url = base + path
            return request
        }
    }

    private func cookie(_ report: RunReport, at index: Int) throws -> String {
        let body = try XCTUnwrap(report.outcomes[index].retainedBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let headers = try XCTUnwrap(object["headers"] as? [String: String])
        return headers.first { $0.key.lowercased() == "cookie" }?.value ?? ""
    }

    func testSharedRunnerUsesExplicitSessionAndExpiresCookies() async throws {
        let requests = try requests()
        let report = try await CollectionRunner.run(
            requests: requests, environment: nil, configuration: RunConfiguration(),
            cookieJar: CookieJar())
        XCTAssertTrue(report.passed)
        XCTAssertEqual(try cookie(report, at: 1), "session=fixture")
        XCTAssertEqual(try cookie(report, at: 3), "")
        let isolated = try await CollectionRunner.run(
            requests: requests, environment: nil, configuration: RunConfiguration())
        XCTAssertEqual(try cookie(isolated, at: 1), "")
    }

    func testConfiguredSessionsAreFreshAndOlderConfigurationsStillDecode() async throws {
        var configuration = RunConfiguration()
        let old = try JSONEncoder().encode(configuration)
        XCTAssertNil(try JSONDecoder().decode(RunConfiguration.self, from: old).cookieSession)
        configuration.cookieSession = true
        let requests = try requests()
        let report = try await CollectionRunner.run(
            requests: Array(requests.prefix(2)), environment: nil, configuration: configuration)
        XCTAssertEqual(try cookie(report, at: 1), "session=fixture")
        let fresh = try await CollectionRunner.run(
            requests: [requests[1]], environment: nil, configuration: configuration)
        XCTAssertEqual(try cookie(fresh, at: 0), "")
        let matrix = try await MatrixRunner.run(
            requests: Array(requests.prefix(2)),
            environments: [Environment(name: "One"), Environment(name: "Two")], concurrency: 2,
            configuration: configuration)
        XCTAssertTrue(matrix.passed)
        for run in matrix.runs { XCTAssertEqual(try cookie(run.report, at: 1), "session=fixture") }
    }

    func testNativeAndPostmanFilePlansShareOnlyTheirSuppliedJar() async throws {
        let requests = try requests()
        var workspace = Workspace()
        workspace.requests = Array(requests.prefix(2))
        let plan = try NativeFileRun.prepare(workspace: JSONEncoder().encode(workspace))
        let native = try await plan.run(configuration: RunConfiguration(), cookieJar: CookieJar())
        XCTAssertTrue(native.passed)
        XCTAssertEqual(try cookie(native, at: 1), "session=fixture")
        let postmanData = try JSONSerialization.data(withJSONObject: [
            "info": [
                "name": "Cookie fixture",
                "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
            ],
            "item": requests.prefix(2).map {
                ["name": "Cookie fixture", "request": ["method": "GET", "url": $0.url]]
            },
        ])
        let postman = try PostmanFileRun.prepare(collection: postmanData)
        let enabled = try await postman.run(
            configuration: RunConfiguration(), cookieJar: CookieJar())
        XCTAssertEqual(try cookie(enabled, at: 1), "session=fixture")
        let fresh = try await postman.run(configuration: RunConfiguration())
        XCTAssertEqual(try cookie(fresh, at: 1), "")
    }

    func testCLIRequiresExplicitCookiesAndDoesNotPersistBetweenRuns() async throws {
        guard let executable = ProcessInfo.processInfo.environment["RILL_TEST_CLI_PATH"] else {
            throw XCTSkip("CLI fixture required")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var workspace = Workspace()
        workspace.requests = Array(try requests().prefix(2))
        let input = root.appendingPathComponent("native.json")
        let output = root.appendingPathComponent("raw.json")
        let report = root.appendingPathComponent("report.json")
        try JSONEncoder().encode(workspace).write(to: input)
        for enabled in [true, false] {
            let result = try await BoundedProcess.run(
                executable: URL(fileURLWithPath: executable),
                arguments: [
                    "run", input.path, "--format", "native", "--output", output.path,
                    "--report", report.path, "--overwrite", "--json",
                ] + (enabled ? ["--cookies"] : []))
            XCTAssertEqual(result.status, 0)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
            let headers = try XCTUnwrap(object["headers"] as? [String: String])
            let value = headers.first { $0.key.lowercased() == "cookie" }?.value ?? ""
            XCTAssertEqual(value, enabled ? "session=fixture" : "")
            let ordinary = try result.output + result.diagnostics + Data(contentsOf: report)
            XCTAssertFalse(String(decoding: ordinary, as: UTF8.self).contains("session=fixture"))
        }
    }
}
