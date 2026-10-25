import Foundation

/// Human reports contain metadata and numeric results only; never dump URLs, payloads or runtime errors.
public enum RunConsole {
    public static func label(_ text: String, limit: Int = 64) -> String {
        let safe = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains($0)
        }))
        return safe.count > limit ? String(safe.prefix(limit - 1)) + "…" : safe
    }
    private static func number(_ value: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func time(_ seconds: Double) -> String { number(seconds * 1000) + " ms" }
    private static func bytes(_ count: Int) -> String { count < 1024 ? "\(count) B" : number(Double(count) / 1024) + " KiB" }
    private static func paint(_ text: String, good: Bool, color: Bool) -> String { color ? "\u{1B}[\(good ? 32 : 31)m\(text)\u{1B}[0m" : text }
    private static func reason(_ failure: String?) -> String {
        guard let failure else { return "One or more checks failed. Review this request's checks in Rill." }
        if let workflow = WorkflowError(rawValue: failure) { return workflow.errorDescription ?? "Workflow failed." }
        switch DiagnosticFailure(rawValue: failure) {
        case .timeout: return "Request timed out. Check the endpoint and timeout setting."
        case .transport: return "Connection failed. Check connectivity, endpoint and TLS settings."
        case .keychainUnavailable: return "Credentials unavailable. Check Keychain access and named secrets."
        case .invalidRequest: return "Invalid request. Review URL, fields and authentication settings."
        case .responseLimit: return "Response exceeded its size budget."
        case .cancelled: return "Execution cancelled."
        default: return "Execution failed; runtime values omitted. Review request configuration."
        }
    }
    public static func render(_ report: RunReport, requests: [RequestDraft], title: String, detail: Bool = false, color: Bool = false) -> String {
        let executed = report.outcomes.filter { $0.state != .notRun }
        // Match the runner's ordered retry semantics, including repeated visits from branches.
        let final = executed.enumerated().filter { index, item in
            guard index + 1 < executed.count else { return true }
            let next = executed[index + 1]
            return !(next.requestID == item.requestID && next.iteration == item.iteration && next.attempt == item.attempt + 1)
        }.map(\.element)
        let passed = final.filter { $0.state == .passed }.count
        let failed = final.filter { $0.state == .failed }.count
        let notRun = report.outcomes.filter { $0.state == .notRun }.count
        let cancelled = final.filter { $0.state == .cancelled }.count
        let attempts = executed.filter { $0.state == .passed || $0.state == .failed }
        let timings = attempts.filter { $0.status != nil }.map(\.duration).sorted()
        let checks = attempts.reduce(0) { $0 + ($1.checkCount ?? $1.checks.count) }
        let failedChecks = attempts.reduce(0) { $0 + ($1.failedCheckCount ?? $1.checks.filter { !$0.passed }.count) }
        let recovered = final.filter { $0.state == .passed && $0.attempt > 1 }.count
        func tableRow(_ label: String, _ total: Int, _ passed: Int, _ failed: Int) -> String {
            label.padding(toLength: 24, withPad: " ", startingAt: 0) + [total, passed, failed].map { String($0).padding(toLength: 12, withPad: " ", startingAt: 0) }.joined()
        }
        let result = report.cancelled ? "CANCELLED" : report.exhausted ? "LIMIT REACHED" : report.passed ? "PASSED" : "FAILED"
        var lines = ["", "RILL / RUN", label(title), String(repeating: "─", count: 58), paint(result, good: report.passed, color: color) + "   ·   " + time(report.duration), "",
                     "                        Total       Passed      Failed",
                     tableRow("Request visits", final.count, passed, failed),
                     tableRow("Checks (all attempts)", checks, checks - failedChecks, failedChecks), "",
                     "Attempts  \(attempts.count)  ·  Retries  \(attempts.filter { $0.attempt > 1 }.count)  ·  Recovered  \(recovered)",
                     "Not run   \(notRun)  ·  Cancelled  \(cancelled)  ·  Planned steps  \(report.requestedSteps)",
                     "Received  \(bytes(attempts.reduce(0) { $0 + $1.bodyBytes })) (response bodies)"]
        if !timings.isEmpty {
            let mean = timings.reduce(0, +) / Double(timings.count)
            lines += ["Latency   avg \(time(mean))  ·  min \(time(timings[0]))  ·  max \(time(timings[timings.count - 1]))", "          p95 \(time(timings[max(0, Int(ceil(Double(timings.count) * 0.95)) - 1)])) · responses only"]
        } else { lines += ["Latency   — (no responses received)"] }
        if report.stopped { lines += ["Flow stopped early (failure policy or workflow stop)."] }
        let lookup = Dictionary(requests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if !detail {
            lines += ["", "REQUEST RESULTS"]
            for row in final.prefix(30) {
                let request = lookup[row.requestID]
                lines += ["  \(paint(row.state.rawValue.uppercased(), good: row.state == .passed, color: color))  \(request?.method.rawValue ?? "HTTP")  \(label(request?.name ?? row.requestID.uuidString, limit: 40))",
                          "        iteration \(row.iteration) · HTTP \(row.status.map(String.init) ?? "—") · \(time(row.duration))" + (row.attempt > 1 ? " · \(row.attempt) attempts" : "")]
            }
            if final.count > 30 { lines += ["  \(final.count - 30) more visits; use --detail or --report."] }
        }
        let rows = detail ? report.outcomes : final.filter { $0.state == .failed || $0.state == .cancelled }
        lines += ["", detail ? "REQUEST DETAILS" : "FAILURES"]
        if rows.isEmpty { lines += [report.passed ? "No terminal failures." : "No completed failure detail; inspect run state above."] }
        for (offset, row) in rows.prefix(200).enumerated() {
            let request = lookup[row.requestID]
            let state = paint(row.state.rawValue.uppercased(), good: row.state == .passed, color: color)
            lines += ["", "\(offset + 1). \(state)  \(request?.method.rawValue ?? "HTTP")  \(label(request?.name ?? row.requestID.uuidString))",
                      "   Iteration \(row.iteration) · Attempt \(row.attempt) · HTTP \(row.status.map(String.init) ?? "—") · \(time(row.duration)) · \(bytes(row.bodyBytes))"]
            if row.state == .failed { lines += ["   " + reason(row.failure)] }
            if row.state == .notRun { lines += ["   Not visited (branch, stop, cancellation or execution limit)."] }
            if detail {
                for (index, check) in row.checks.prefix(50).enumerated() { lines += ["   \(check.passed ? "PASS" : "FAIL")  Check \(index + 1)"] }
                let omitted = (row.checkCount ?? row.checks.count) - min(50, row.checks.count)
                if omitted > 0 { lines += ["   \(omitted) additional check results omitted from this view."] }
                if row.checks.isEmpty && (row.checkCount ?? 0) == 0 { lines += ["   No checks recorded."] }
            } else {
                lines += ["   Request ID: \(row.requestID)"]
            }
        }
        if rows.count > 200 { lines += ["", "\(rows.count - 200) more results; use --report for the full run."] }
        lines += ["", detail ? "Check labels and runtime values are omitted; inspect saved check definitions in Rill." : "Use --detail for every attempt and check; --report FILE saves a full run artifact.", ""]
        return lines.joined(separator: "\n")
    }
    public static func renderLoad(_ report: LoadReport, title: String, detail: Bool = false, color: Bool = false) -> String {
        var lines = ["", "RILL / PERFORMANCE", label(title), String(repeating: "─", count: 58), paint(report.passed ? "PASSED" : report.cancelled ? "CANCELLED" : "FAILED", good: report.passed, color: color),
                     "", "Samples \(report.samples.count) · Passed \(report.successes) · Failed \(report.failures) · Not completed \(report.samples.count - report.successes - report.failures)",
                     "Elapsed \(time(report.duration)) · Throughput \(number(report.throughput)) requests/s",
                     "Latency p50 \(report.percentile(0.5).map(time) ?? "—") · p95 \(report.percentile(0.95).map(time) ?? "—") · p99 \(report.percentile(0.99).map(time) ?? "—")",
                     "Min \(report.minimum.map(time) ?? "—") · Max \(report.maximum.map(time) ?? "—")", "Latency includes failed attempts; unexecuted samples excluded."]
        if detail { for sample in report.samples.prefix(200) { lines += ["#\(sample.index + 1)  \(sample.state.rawValue.uppercased())  HTTP \(sample.status.map(String.init) ?? "—")  \(time(sample.duration))"] }; if report.samples.count > 200 { lines += ["Additional samples omitted; use --json for all samples."] } }
        return lines.joined(separator: "\n") + "\n"
    }
}
