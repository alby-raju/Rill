import Foundation
import XCTest

@testable import RillCore

private actor EnvironmentCapture {
    var values: [String: String]?
    func save(_ values: [String: String]) { self.values = values }
}

@MainActor final class FinalEnvironmentTests: XCTestCase {
    func testExplicitExportIsDeterministicAndRoundTripsWithoutResolvingSecrets() throws {
        let values = ["z": "{{secret:token}}", "empty": "", "a": "private-export-value"]
        let bytes = try FinalEnvironmentExport.encode(values)
        XCTAssertEqual(bytes, try FinalEnvironmentExport.encode(values))
        let imported = try PostmanImporter.parse(bytes)
        XCTAssertEqual(WorkflowEngine.variables(in: imported.workspace.environments.first), values)
        XCTAssertThrowsError(
            try FinalEnvironmentExport.encode([String(repeating: "x", count: 129): ""]))
    }

    func testExportUsesOnlyCommittedStateAndNeverEntersReport() async throws {
        let capture = EnvironmentCapture()
        var configuration = RunConfiguration()
        configuration.stopOnFailure = false
        let first = RequestDraft()
        let second = RequestDraft()
        let report = try await CollectionRunner.run(
            requests: [first, second],
            environment: WorkflowEngine.environment(["seed": "original"]),
            configuration: configuration,
            exportEnvironment: { await capture.save($0) },
            executor: { request, values in
                var updated = values
                updated["seed"] =
                    request.id == first.id ? "private-committed" : "private-rolled-back"
                return WorkflowStepResult(
                    exchange: RunnerTests.exchange(request, passed: request.id == first.id),
                    variables: updated, stop: false)
            })
        let final = await capture.values
        XCTAssertEqual(final, ["seed": "private-committed"])
        XCTAssertFalse(report.passed)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(report), as: UTF8.self).contains("private-"))
    }

    func testIterationRowsExportLastRowAndCancellationSkipsExport() async throws {
        let capture = EnvironmentCapture()
        var configuration = RunConfiguration()
        configuration.iterations = 2
        let data = try IterationData(
            data: Data(#"[{"row":"first"},{"row":"last"}]"#.utf8), format: .json)
        _ = try await CollectionRunner.run(
            requests: [RequestDraft()], environment: nil, configuration: configuration,
            iterationData: data, exportEnvironment: { await capture.save($0) },
            executor: { request, values in
                WorkflowStepResult(
                    exchange: RunnerTests.exchange(request), variables: values, stop: false)
            })
        let final = await capture.values
        XCTAssertEqual(final, ["row": "last"])
        let cancelledCapture = EnvironmentCapture()
        let report = try await CollectionRunner.run(
            requests: [RequestDraft()], environment: nil, configuration: RunConfiguration(),
            exportEnvironment: { await cancelledCapture.save($0) },
            executor: { _, _ in throw CancellationError() })
        XCTAssertTrue(report.cancelled)
        let missing = await cancelledCapture.values
        XCTAssertNil(missing)
    }
}
