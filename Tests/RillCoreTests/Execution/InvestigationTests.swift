import XCTest

@testable import RillCore

@MainActor final class InvestigationTests: XCTestCase {
    nonisolated static func result(_ request: RequestDraft) -> WorkflowStepResult {
        WorkflowStepResult(
            exchange: RunnerTests.exchange(request), variables: [:], next: nil, stop: false)
    }
    func testSeededTemplatesHaveStableVersionedVectorsAndRestoreAmbientState() async throws {
        let uuid = try await DynamicTemplates.withSeed(0) { try DynamicTemplates.generate("$uuid") }
        XCTAssertEqual(uuid, "e220a839-7b1d-4daf-ae78-9e6aa1b965f4")
        func sequence(_ seed: UInt64) async throws -> [String] {
            try await DynamicTemplates.withSeed(seed, epochSeconds: 123) {
                var values = [
                    try DynamicTemplates.generate("$uuid"), try DynamicTemplates.generate("$email"),
                    try DynamicTemplates.generate("$timestamp"),
                ]
                for _ in 0..<100 { values.append(try DynamicTemplates.generate("$randomInt -2 2")) }
                values.append(
                    try DynamicTemplates.generate(
                        "$randomInt -9223372036854775808 9223372036854775807"))
                return values
            }
        }
        let first = try await sequence(42)
        let second = try await sequence(42)
        let other = try await sequence(43)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first[2], "123")
        XCTAssertTrue(first[3..<103].allSatisfy { (-2...2).contains(Int($0)!) })
        XCTAssertNotEqual(try DynamicTemplates.generate("$timestamp"), "123")
        var config = RunConfiguration()
        config.seedTimestamp = 123
        XCTAssertThrowsError(try config.validate())
    }
    func testExecutionDeadlineCancelsActiveRequestAndDoesNotRetryOrLookPassed() async throws {
        var config = RunConfiguration()
        config.totalDeadlineSeconds = 0.04
        config.retries = 5
        let report = try await CollectionRunner.run(
            requests: [RequestDraft(), RequestDraft()], environment: nil, configuration: config,
            executor: { request, _ in
                try await Task.sleep(for: .seconds(10))
                return Self.result(request)
            })
        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.timedOut, true)
        XCTAssertEqual(report.outcomes.filter { $0.state == .failed }.count, 1)
        XCTAssertEqual(report.outcomes.first?.failureKind, .deadline)
        XCTAssertLessThan(report.duration, 2)
        config.totalDeadlineSeconds = .nan
        XCTAssertThrowsError(try config.validate())
    }
    func testPacingDeadlineAndExternalCancellationRemainDistinct() async throws {
        var config = RunConfiguration()
        config.totalDeadlineSeconds = 0.04
        config.delayMilliseconds = 200
        let report = try await CollectionRunner.run(
            requests: [RequestDraft(), RequestDraft()], environment: nil, configuration: config,
            executor: { request, _ in Self.result(request) })
        XCTAssertEqual(report.timedOut, true)
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.outcomes.last?.failureKind, .deadline)
        let task = Task {
            try await CollectionRunner.run(
                requests: [RequestDraft()], environment: nil, configuration: RunConfiguration(),
                executor: { request, _ in
                    try await Task.sleep(for: .seconds(10))
                    return Self.result(request)
                })
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let cancelled = try await task.value
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertNotEqual(cancelled.timedOut, true)
    }
    func testPostmanSourceIDsAreRepeatableAndSelectionPreservesOriginalPositions() throws {
        let data = Data(
            #"{"info":{"name":"Synthetic","schema":"https://schema.getpostman.com/json/collection/v2.1.0/collection.json"},"item":[{"name":"A","item":[{"name":"One","request":{"method":"GET","url":"https://example.test/a"}}]},{"name":"B","item":[{"name":"Two","request":{"method":"GET","url":"https://example.test/b"}}]}]}"#
                .utf8)
        let first = try PostmanFileRun.prepare(collection: data)
        let second = try PostmanFileRun.prepare(collection: data)
        let folder = try PostmanFileRun.prepare(collection: data, folder: "/B")
        XCTAssertEqual(first.requests.map(\.id), second.requests.map(\.id))
        XCTAssertEqual(folder.requests.first?.id, first.requests.last?.id)
        XCTAssertEqual(folder.sourceLocations[folder.requests[0].id.uuidString], "/item/1/item/0")
    }
    func report(body: String = #"{"value":1}"#) -> RunReport {
        let data = Data(body.utf8)
        var report = RunReport(requestedSteps: 1)
        let id = UUID()
        report.sourceFormat = "native-id-v1"
        report.sources = [id.uuidString: "/requests/0"]
        report.outcomes = [
            RunAttempt(
                requestID: id, iteration: 1, attempt: 1, state: .passed, status: 200, duration: 0.1,
                checks: [CheckResult(title: "PRIVATE-SENTINEL", passed: true)], retainedBody: data,
                responseHeaders: [Field(name: "X-Token", value: "PRIVATE-SENTINEL")],
                headersOmitted: false, bodyBytes: data.count, bodyOmitted: false)
        ]
        return report
    }
    func testVersionedJSONAndNDJSONShareRedactionAndFinalState() throws {
        var report = report(body: #"{"secret":"PRIVATE-SENTINEL"}"#)
        report.outcomes[0].failure = "PRIVATE-SENTINEL"
        report.outcomes[0].failureKind = .transport
        report.outcomes[0].state = .failed
        let json = try XCTUnwrap(RunReportExporter.files(report, format: .json).values.first)
        let decoded = try RunSnapshotFile.decode(json)
        XCTAssertNil(decoded.outcomes[0].responseHeaders)
        XCTAssertNil(decoded.outcomes[0].retainedBody)
        XCTAssertEqual(decoded.outcomes[0].failureKind, .transport)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("PRIVATE-SENTINEL"))
        let events = try XCTUnwrap(RunReportExporter.files(report, format: .ndjson).values.first)
        XCTAssertFalse(String(decoding: events, as: UTF8.self).contains("PRIVATE-SENTINEL"))
        let lines = try events.split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0]["type"] as? String, "started")
        XCTAssertEqual(lines[2]["passed"] as? Bool, false)
        XCTAssertEqual(lines[2]["sequence"] as? Int, 2)
        let raw = try RunSnapshotFile.encode(report)
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains("PRIVATE-SENTINEL"))
        let restored = try RunSnapshotFile.decode(raw)
        XCTAssertEqual(restored.outcomes[0].retainedBody, report.outcomes[0].retainedBody)
    }
    func testComparisonDetectsNormalizedBodySchemaHeadersLatencyAndRetryDrift() throws {
        let before = report(body: #"{"items":[{"a":1},{"b":"x"}]}"#)
        var after = before
        let body = Data(#"{"items":[{"b":"y"},{"a":2}]}"#.utf8)
        after.outcomes[0].retainedBody = body
        after.outcomes[0].bodyBytes = body.count
        after.outcomes[0].duration = 0.3
        after.outcomes[0].attempt = 2
        after.outcomes[0].responseHeaders = [Field(name: "X-Token", value: "changed-secret")]
        let comparison = try RunComparator.compare(before, after)
        XCTAssertTrue(comparison.changed)
        XCTAssertTrue(comparison.complete)
        XCTAssertEqual(comparison.changes[0].bodyChanged, true)
        XCTAssertEqual(comparison.changes[0].schemaChanged, false)
        XCTAssertEqual(comparison.changes[0].headersChanged, true)
        XCTAssertTrue(comparison.changes[0].latencyRegression)
        XCTAssertTrue(comparison.changes[0].retriesChanged)
        let output = String(decoding: try JSONEncoder().encode(comparison), as: UTF8.self)
        XCTAssertFalse(output.contains("changed-secret"))
        XCTAssertFalse(output.contains("PRIVATE-SENTINEL"))
        XCTAssertTrue(output.contains("\"complete\":true"))
    }
    func testIgnoreRulesApplyToValueAndSchemaWithExactPointerEscapes() throws {
        let before = report(body: #"{"a/b":{"~time":1},"value":true}"#)
        var after = before
        after.outcomes[0].retainedBody = Data(#"{"value":true,"a/b":{"~time":"changed"}}"#.utf8)
        after.outcomes[0].bodyBytes = after.outcomes[0].retainedBody!.count
        var options = RunComparisonOptions()
        options.ignoreJSONPointers = ["/a~1b/~0time"]
        let comparison = try RunComparator.compare(before, after, options: options)
        XCTAssertFalse(comparison.changed)
        XCTAssertTrue(comparison.complete)
        XCTAssertEqual(comparison.changes[0].schemaChanged, false)
        options.ignoreJSONPointers = ["/~bad"]
        XCTAssertThrowsError(try RunComparator.compare(before, after, options: options))
    }
    func testMissingDataIsUnknownAndMetadataComparisonIsExplicit() throws {
        let source = report()
        let json = try XCTUnwrap(RunReportExporter.files(source, format: .json).values.first)
        let safe = try RunSnapshotFile.decode(json)
        let comparison = try RunComparator.compare(safe, safe)
        XCTAssertFalse(comparison.complete)
        XCTAssertFalse(comparison.changed)
        XCTAssertNil(comparison.changes[0].bodyChanged)
        XCTAssertNil(comparison.changes[0].headersChanged)
        var options = RunComparisonOptions()
        options.metadataOnly = true
        let metadata = try RunComparator.compare(safe, safe, options: options)
        XCTAssertTrue(metadata.complete)
        XCTAssertFalse(metadata.changed)
        var after = source
        after.outcomes = []
        let missing = try RunComparator.compare(source, after)
        XCTAssertTrue(missing.changed)
        XCTAssertTrue(missing.changes[0].missingAfter)
    }
    func testCheckPatternsAndNotRunStatesAreCompared() throws {
        var before = report()
        before.outcomes[0].checks = [
            CheckResult(title: "", passed: true), CheckResult(title: "", passed: false),
        ]
        var after = before
        after.outcomes[0].checks.reverse()
        let comparison = try RunComparator.compare(before, after)
        XCTAssertEqual(comparison.changes[0].assertionsChanged, true)
        after.outcomes[0].state = .notRun
        after.outcomes[0].attempt = 0
        XCTAssertTrue(try RunComparator.compare(before, after).changes[0].stateChanged)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: RunSnapshotFile.encode(before)) as? [String: Any])
        object["schemaVersion"] = true
        XCTAssertThrowsError(
            try RunSnapshotFile.decode(JSONSerialization.data(withJSONObject: object)))
        object["schemaVersion"] = 2
        XCTAssertThrowsError(
            try RunSnapshotFile.decode(JSONSerialization.data(withJSONObject: object)))
        var invalid = before
        invalid.outcomes[0].checkCount = -1
        XCTAssertThrowsError(try RunSnapshotFile.decode(RunSnapshotFile.encode(invalid)))

    }
}
