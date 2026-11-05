import CryptoKit
import Foundation
import XCTest

@testable import RillCore

@MainActor final class HTMLReportTests: XCTestCase {
    func testOfflineReportOmitsHostilePayloadsAndPinsItsLocalScript() throws {
        let hostile =
            "</script><img src=https://example.invalid/steal onerror=alert(1)>\u{0}private-value"
        var report = RunReport(requestedSteps: 1)
        report.outcomes = [
            RunAttempt(
                requestID: UUID(), iteration: 1, attempt: 1, state: .failed, status: 500,
                duration: 0.25, checks: [CheckResult(title: hostile, passed: false)],
                failure: hostile, fingerprint: hostile, retainedBody: Data(hostile.utf8),
                bodyBytes: hostile.utf8.count, bodyOmitted: false)
        ]
        let bytes = try XCTUnwrap(RunReportExporter.files(report, format: .html)["rill-run.html"])
        let html = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(html.contains("example.invalid"))
        XCTAssertFalse(html.contains("private-value"))
        XCTAssertFalse(html.contains("onerror"))
        XCTAssertTrue(html.contains("Unsuccessful"))
        XCTAssertTrue(html.contains("1 / 1"))
        XCTAssertTrue(html.contains("data-state=\"failed\""))
        XCTAssertTrue(html.contains("default-src 'none'"))
        let start = try XCTUnwrap(html.range(of: "<script>"))
        let end = try XCTUnwrap(
            html.range(of: "</script>", range: start.upperBound..<html.endIndex))
        let script = String(html[start.upperBound..<end.lowerBound])
        let digest = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        XCTAssertTrue(html.contains("script-src 'sha256-\(digest)'"))
        XCTAssertFalse(html.contains("script-src 'unsafe-inline'"))
        XCTAssertTrue(html.contains("<noscript>"))
    }

    func testEmptyCancelledAndExhaustedRunsCannotRenderGreen() throws {
        for state in 0..<3 {
            var report = RunReport(requestedSteps: 1)
            report.cancelled = state == 1
            report.exhausted = state == 2
            let bytes = try XCTUnwrap(RunReportExporter.files(report, format: .html).values.first)
            XCTAssertTrue(
                String(decoding: bytes, as: UTF8.self).contains("<strong>Unsuccessful</strong>"))
        }
        var invalid = RunReport(requestedSteps: 0)
        invalid.duration = .infinity
        XCTAssertThrowsError(try RunReportExporter.files(invalid, format: .html))
    }
}
