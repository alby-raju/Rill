import XCTest
@testable import RillCore

final class RunConsoleTests: XCTestCase {
    func attempt(_ request: RequestDraft, _ state: RunState, attempt: Int = 1, status: Int? = 200, duration: Double = 0.1) -> RunAttempt {
        RunAttempt(requestID: request.id, iteration: 1, attempt: attempt, state: state, status: status, duration: duration, checks: [CheckResult(title: "private-check-value", passed: state == .passed)], failure: nil, retainedBody: Data("private-body".utf8), bodyBytes: 12, bodyOmitted: false)
    }
    func testRecoveredRetryCountsAndDetailRemainConsistentWithRunner() {
        var request = RequestDraft(); request.name = "Health"; request.url = "https://private-url.test?secret=x"
        let report = RunReport(duration: 0.4, outcomes: [attempt(request, .failed), attempt(request, .passed, attempt: 2)], requestedSteps: 1)
        XCTAssertTrue(report.passed)
        let summary = RunConsole.render(report, requests: [request], title: "Smoke")
        XCTAssertTrue(summary.contains("PASSED")); XCTAssertTrue(summary.contains("Recovered  1")); XCTAssertTrue(summary.contains("Retries  1")); XCTAssertTrue(summary.contains("No terminal failures."))
        let detail = RunConsole.render(report, requests: [request], title: "Smoke", detail: true)
        XCTAssertTrue(detail.contains("Attempt 1")); XCTAssertTrue(detail.contains("Attempt 2")); XCTAssertTrue(detail.contains("FAIL  Check 1"))
        for text in [summary, detail] { for secret in ["private-url", "private-body", "private-check-value"] { XCTAssertFalse(text.contains(secret)) }; XCTAssertFalse(text.contains("\u{1B}")) }
    }
    func testFailureDiagnosticIsAllowlistedAndTerminalLabelsCannotInjectControls() {
        var request = RequestDraft(); request.name = "Danger\u{1B}[2J\n\u{202E}name"
        var failure = attempt(request, .failed, status: nil); failure.failure = "timeout"
        let report = RunReport(outcomes: [failure], requestedSteps: 1)
        let text = RunConsole.render(report, requests: [request], title: "test\r\n\u{1B}]8;;bad\u{7}")
        XCTAssertLessThanOrEqual(RunConsole.label("a" + String(repeating: "\u{301}", count: 10_000)).unicodeScalars.count, 513)
        XCTAssertEqual(RunConsole.label("test", limit: 0), "…")
        XCTAssertTrue(text.contains("Request timed out")); XCTAssertTrue(text.contains("no responses received")); XCTAssertFalse(text.contains("\u{1B}")); XCTAssertFalse(text.contains("\u{202E}"))
        failure.failure = "secret-runtime-error"
        XCTAssertFalse(RunConsole.render(RunReport(outcomes: [failure], requestedSteps: 1), requests: [request], title: "test").contains("secret-runtime-error"))
    }
    func testStoppedCancelledEmptyAndLimitRunsDoNotClaimSuccess() {
        let request = RequestDraft()
        let empty = RunConsole.render(RunReport(requestedSteps: 0), requests: [], title: "Empty")
        XCTAssertTrue(empty.contains("FAILED")); XCTAssertTrue(empty.contains("no responses received"))
        let report = RunReport(outcomes: [attempt(request, .cancelled, status: nil)], cancelled: true, stopped: true, requestedSteps: 2)
        let cancelled = RunConsole.render(report, requests: [request], title: "Cancel", detail: true)
        XCTAssertTrue(cancelled.contains("CANCELLED")); XCTAssertTrue(cancelled.contains("Flow stopped early"))
        let limited = RunConsole.render(RunReport(exhausted: true, requestedSteps: 4), requests: [], title: "Limit")
        XCTAssertTrue(limited.contains("LIMIT REACHED"))
        let cancelledRetry = RunReport(outcomes: [attempt(request, .failed, status: nil), attempt(request, .cancelled, attempt: 2, status: nil)], cancelled: true, requestedSteps: 1)
        XCTAssertTrue(RunConsole.render(cancelledRetry, requests: [request], title: "Cancel").contains("Retries  0"))
    }
    func testDetailHasBoundedOutputAndOmittedChecksAreExplicit() {
        let request = RequestDraft(); var row = attempt(request, .failed)
        row.checks = []; row.checkCount = 120; row.failedCheckCount = 100; row.checksOmitted = true
        let report = RunReport(outcomes: Array(repeating: row, count: 220), requestedSteps: 220)
        let text = RunConsole.render(report, requests: [request], title: "Large", detail: true, color: true)
        XCTAssertTrue(text.contains("20 more results")); XCTAssertTrue(text.contains("120 additional check results")); XCTAssertTrue(text.contains("\u{1B}[31m"))
    }
    func testPerformancePercentilesAndUnexecutedSamples() {
        let report = LoadReport(samples: [LatencySample(index: 0, state: .passed, duration: 0.01, status: 200), LatencySample(index: 1, state: .failed, duration: 0.1, status: 500), LatencySample(index: 2, state: .notRun, duration: 0, status: nil)], duration: 0.2)
        let text = RunConsole.renderLoad(report, title: "Load", detail: true)
        XCTAssertTrue(text.contains("CANCELLED")); XCTAssertTrue(text.contains("p95 100.0 ms")); XCTAssertTrue(text.contains("Not completed 1")); XCTAssertTrue(text.contains("10.0 requests/s")); XCTAssertTrue(text.contains("HTTP 500"))
    }
}
