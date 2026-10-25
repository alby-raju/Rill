import Foundation

public enum RunReportFormat: String, CaseIterable, Sendable {
    case json = "JSON", markdown = "Markdown", junit = "JUnit XML", allure = "Allure results"
}
public enum RunReportExporter {
    /// Allowlist only. Labels, URLs, checks' expected values, bodies, fingerprints and errors may contain secrets.
    private static func sanitized(_ report: RunReport) -> RunReport {
        var copy = report
        for index in copy.outcomes.indices {
            copy.outcomes[index].retainedBody = nil
            copy.outcomes[index].bodyOmitted = true
            copy.outcomes[index].fingerprint = nil
            copy.outcomes[index].checkSignature = nil
            copy.outcomes[index].checks = copy.outcomes[index].checks.enumerated().map {
                offset, check in CheckResult(title: "Check \(offset + 1)", passed: check.passed)
            }
            if copy.outcomes[index].failure != nil {
                copy.outcomes[index].failure = "Execution unsuccessful; runtime details omitted"
            }
        }
        return copy
    }
    public static func write(_ data: Data, to url: URL) throws {
        guard data.count <= 32 * 1024 * 1024 else { throw WorkflowError.limit }
        try Task.checkCancellation()
        try WorkspaceFile.atomicWrite(data, to: url)
    }
    static func xml(_ text: String) -> String {
        let clean = String(
            text.unicodeScalars.filter {
                $0.value == 9 || $0.value == 10 || $0.value == 13
                    || $0.value >= 32 && $0.value <= 0xD7FF
                    || $0.value >= 0xE000 && $0.value <= 0xFFFD
                    || $0.value >= 0x10000 && $0.value <= 0x10FFFF
            })
        return clean.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
            of: "<", with: "&lt;"
        ).replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    public static func files(_ report: RunReport, format: RunReportFormat) throws -> [String: Data]
    {
        guard report.duration.isFinite, (0...1e12).contains(report.duration),
            report.started.timeIntervalSince1970.isFinite,
            (0...1e12).contains(report.started.timeIntervalSince1970),
            report.outcomes.count <= 20_000,
            report.outcomes.reduce(0, { $0 + $1.checks.count }) <= 100_000,
            report.outcomes.allSatisfy({
                $0.duration.isFinite && (0...1e12).contains($0.duration)
                    && ($0.started.map {
                        $0.timeIntervalSince1970.isFinite
                            && (0...1e12).contains($0.timeIntervalSince1970)
                    } ?? true)
            })
        else { throw WorkflowError.limit }
        let safe = sanitized(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let files: [String: Data]
        switch format {
        case .json:
            var object =
                try JSONSerialization.jsonObject(with: encoder.encode(safe)) as! [String: Any]
            object["passed"] = safe.passed
            files = [
                "rill-run.json": try JSONSerialization.data(
                    withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            ]
        case .markdown:
            let text =
                "# Rill run\n\nResult: \(safe.passed ? "passed" : "unsuccessful") · Cancelled: \(safe.cancelled) · Budget exhausted: \(safe.exhausted)\n\n| Request ID | Iteration | Attempt | State | Status | Seconds |\n|---|---:|---:|---|---:|---:|\n"
                + safe.outcomes.map {
                    "| \($0.requestID) | \($0.iteration) | \($0.attempt) | \($0.state.rawValue) | \($0.status.map(String.init) ?? "—") | \($0.duration) |"
                }.joined(separator: "\n") + "\n"
            files = ["rill-run.md": Data(text.utf8)]
        case .junit:
            let failures = safe.outcomes.filter { $0.state == .failed }.count
            let skipped = safe.outcomes.filter { $0.state == .notRun || $0.state == .cancelled }
                .count
            var cases = safe.outcomes.map { outcome in
                let tag =
                    outcome.state == .failed
                    ? "<failure message=\"Execution unsuccessful\"/>"
                    : outcome.state == .passed
                        ? "" : "<skipped message=\"\(outcome.state.rawValue)\"/>"
                return
                    "<testcase classname=\"Rill\" name=\"\(outcome.requestID)-\(outcome.iteration)-\(outcome.attempt)\" time=\"\(outcome.duration)\">\(tag)</testcase>"
            }
            let needsSummaryFailure = !safe.passed && failures == 0
            if needsSummaryFailure {
                cases.append(
                    "<testcase name=\"run-status\"><failure message=\"Empty, cancelled or exhausted runs cannot pass\"/></testcase>"
                )
            }
            let text =
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><testsuite name=\"Rill\" tests=\"\(cases.count)\" failures=\"\(failures + (needsSummaryFailure ? 1 : 0))\" skipped=\"\(skipped)\" time=\"\(safe.duration)\">"
                + cases.joined() + "</testsuite>"
            files = ["rill-run.xml": Data(text.utf8)]
        case .allure:
            var results: [String: Data] = [:]
            for outcome in safe.outcomes {
                let status =
                    outcome.state == .passed
                    ? "passed" : outcome.state == .failed ? "failed" : "skipped"
                let start = Int64((outcome.started ?? safe.started).timeIntervalSince1970 * 1000)
                let object: [String: Any] = [
                    "uuid": outcome.id.uuidString,
                    "name": "Request " + outcome.requestID.uuidString,
                    "fullName": "rill." + outcome.requestID.uuidString,
                    "status": status, "stage": "finished", "start": start,
                    "stop": start + Int64(outcome.duration * 1000),
                    "labels": [["name": "framework", "value": "Rill"]],
                    "statusDetails": [
                        "message": status == "passed" ? "" : "Execution unsuccessful or not run"
                    ],
                ]
                results[outcome.id.uuidString + "-result.json"] = try JSONSerialization.data(
                    withJSONObject: object, options: [.sortedKeys])
            }
            if !safe.passed && !safe.outcomes.contains(where: { $0.state == .failed }) {
                let id = UUID().uuidString
                results[id + "-result.json"] = try JSONSerialization.data(
                    withJSONObject: [
                        "uuid": id, "name": "Unsuccessful Rill run", "status": "failed",
                        "stage": "finished",
                        "statusDetails": [
                            "message": "Empty, cancelled or exhausted runs cannot pass"
                        ],
                    ], options: [.sortedKeys])
            }
            files = results
        }
        guard files.count <= 20_000, files.values.reduce(0, { $0 + $1.count }) <= 32 * 1024 * 1024
        else { throw WorkflowError.limit }
        return files
    }
}
